import Foundation

public enum TokenCountFormatter {
    public static func compact(_ value: Int64) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        if value >= 1_000_000_000 { return String(format: "%.1fB", locale: locale, Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", locale: locale, Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fK", locale: locale, Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fK", locale: locale, Double(value) / 1_000) }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

/// Reads only Codex token-count metadata from today's local session logs.
/// Message text and tool output are never retained or emitted.
public final class LocalTokenUsageCounter: @unchecked Sendable {
    private struct LogEvent: Decodable {
        let type: String?
        let timestamp: String?
        let payload: EventPayload?
    }

    private struct EventPayload: Decodable {
        let type: String?
        let info: TokenUsageInfo?
    }

    private struct TokenUsageInfo: Decodable {
        let lastTokenUsage: TokenUsage?
    }

    private struct TokenUsage: Decodable {
        let totalTokens: Int64?
    }

    private struct FileState {
        var bytesRead: UInt64 = 0
        var pendingLine = Data()
        var tokens: Int64 = 0
    }

    private let lock = NSLock()
    private let codexHomeURL: URL
    private var dayStart: Date?
    private var fileStates: [URL: FileState] = [:]
    private var latestDate: String?
    private var latestTokens: Int64?
    private var lastCSVWriteAt: Date?
    private var lastCSVWriteDate: String?

    private static let csvWriteInterval: TimeInterval = 5 * 60

    public init(codexHomeURL: URL? = nil) {
        if let codexHomeURL {
            self.codexHomeURL = codexHomeURL
        } else if let configuredPath = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            self.codexHomeURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
        } else {
            self.codexHomeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
    }

    public var sessionsDirectoryURL: URL {
        codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Rebuilds the counter from today's session files. Use at startup, day rollover, and recovery.
    @discardableResult
    public func reconcileToday(now: Date = Date()) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: sessionsDirectoryURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        prepareDay(for: now)
        return try reconcileTodayLocked(now: now)
    }

    /// Processes only changed JSONL paths. Missing, rotated, or truncated paths are reconciled safely.
    @discardableResult
    public func processChangedFiles(_ urls: [URL], now: Date = Date()) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: sessionsDirectoryURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let previousDay = dayStart
        prepareDay(for: now)
        if previousDay != dayStart {
            return try reconcileTodayLocked(now: now)
        }

        let rootPath = sessionsDirectoryURL.standardizedFileURL.path + "/"
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        for inputURL in Set(urls.map(\.standardizedFileURL)) {
            guard inputURL.path.hasPrefix(rootPath),
                  inputURL.pathExtension == "jsonl",
                  !inputURL.lastPathComponent.hasPrefix(".") else { continue }
            guard let values = try? inputURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  let dayStart,
                  modified >= dayStart else {
                fileStates.removeValue(forKey: inputURL)
                continue
            }
            processFile(inputURL, values: values, now: now)
        }
        return updateTotal(now: now)
    }

    private func reconcileTodayLocked(now: Date) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: sessionsDirectoryURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let calendar = Calendar.current
        fileStates.removeAll(keepingCapacity: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return updateTotal(now: now) }
        var seenFiles = Set<URL>()
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= (dayStart ?? calendar.startOfDay(for: now)) else { continue }
            let normalizedURL = url.standardizedFileURL
            seenFiles.insert(normalizedURL)
            processFile(normalizedURL, values: values, now: now)
        }
        fileStates = fileStates.filter { seenFiles.contains($0.key) }
        return updateTotal(now: now)
    }

    private func prepareDay(for now: Date) {
        let start = Calendar.current.startOfDay(for: now)
        if dayStart != start {
            dayStart = start
            fileStates.removeAll(keepingCapacity: true)
        }
    }

    private func processFile(_ url: URL, values: URLResourceValues, now: Date) {
        var state = fileStates[url] ?? FileState()
        let currentSize = UInt64(values.fileSize ?? 0)
        if currentSize < state.bytesRead {
            state = FileState()
        }
        if currentSize > state.bytesRead {
            do {
                let file = try FileHandle(forReadingFrom: url)
                try file.seek(toOffset: state.bytesRead)
                let appended = try file.readToEnd() ?? Data()
                try file.close()
                state.bytesRead += UInt64(appended.count)
                state.pendingLine.append(appended)
                consumeCompleteLines(in: &state, calendar: .current, now: now)
            } catch {
                return
            }
        }
        fileStates[url] = state
    }

    private func updateTotal(now: Date) -> Int64 {
        let total = fileStates.values.reduce(0) { $0 + $1.tokens }
        let date = Self.dateString(for: now)
        let changed = latestDate != date || latestTokens != total
        latestDate = date
        latestTokens = total

        let isNewDay = lastCSVWriteDate != date
        let intervalElapsed = lastCSVWriteAt.map { now.timeIntervalSince($0) >= Self.csvWriteInterval } ?? true
        if isNewDay || (changed && intervalElapsed) {
            persistLatestTotal(at: now)
        }
        return total
    }

    /// Flush the most recent total when the app is shutting down.
    public func flushLatestTotal() {
        lock.lock()
        defer { lock.unlock() }
        guard latestDate != nil, latestTokens != nil else { return }
        persistLatestTotal(at: Date())
    }

    public func prepareDailyLogForViewing() throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let url = codexHomeURL.appendingPathComponent("daily-token-usage.csv")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("date,tokens,last_updated_at\n".utf8).write(to: url, options: .atomic)
        return url
    }

    private func persistLatestTotal(at now: Date) {
        guard let date = latestDate, let tokens = latestTokens else { return }
        do {
            let fileURL = codexHomeURL.appendingPathComponent("daily-token-usage.csv")
            try Self.writeCSV(date: date, tokens: tokens, updatedAt: now, to: fileURL)
            lastCSVWriteAt = now
            lastCSVWriteDate = date
        } catch {
            // Persistence is best-effort and must not stop the menu bar counter.
        }
    }

    private static func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func writeCSV(date: String, tokens: Int64, updatedAt: Date, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        struct Row {
            var date: String
            var tokens: Int64
            var lastUpdatedAt: String
        }

        var rows: [Row] = []
        if FileManager.default.fileExists(atPath: url.path) {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let lines = contents.split(whereSeparator: \.isNewline)
            let header = lines.first?.split(separator: ",", omittingEmptySubsequences: false) ?? []
            let tokenIndex = header.firstIndex(of: "tokens") ?? 1
            let timestampIndex = header.firstIndex(of: "last_updated_at")

            for line in lines.dropFirst() {
                let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                guard columns.count > tokenIndex, let count = Int64(columns[tokenIndex]) else { continue }
                rows.append(Row(
                    date: String(columns[0]),
                    tokens: count,
                    lastUpdatedAt: timestampIndex.flatMap { columns.indices.contains($0) ? String(columns[$0]) : nil } ?? ""
                ))
            }
        }

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter.timeZone = .current
        let timestamp = timestampFormatter.string(from: updatedAt)
        if let index = rows.firstIndex(where: { $0.date == date }) {
            rows[index].tokens = tokens
            rows[index].lastUpdatedAt = timestamp
        } else {
            rows.append(Row(date: date, tokens: tokens, lastUpdatedAt: timestamp))
        }
        rows.sort { $0.date < $1.date }

        var csv = "date,tokens_compact,tokens,last_updated_at\n"
        csv += rows.map {
            "\($0.date),\(TokenCountFormatter.compact($0.tokens)),\($0.tokens),\($0.lastUpdatedAt)"
        }.joined(separator: "\n")
        csv += "\n"
        try Data(csv.utf8).write(to: url, options: .atomic)
    }

    private func consumeCompleteLines(in state: inout FileState, calendar: Calendar, now: Date) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        while let newline = state.pendingLine.firstIndex(of: 0x0A) {
            let line = Data(state.pendingLine[..<newline])
            state.pendingLine.removeSubrange(...newline)
            guard let event = try? decoder.decode(LogEvent.self, from: line),
                  event.type == "event_msg",
                  let timestampText = event.timestamp,
                  let timestamp = formatter.date(from: timestampText),
                  calendar.isDate(timestamp, inSameDayAs: now),
                  event.payload?.type == "token_count",
                  let totalTokens = event.payload?.info?.lastTokenUsage?.totalTokens else { continue }
            state.tokens += totalTokens
        }
    }
}
