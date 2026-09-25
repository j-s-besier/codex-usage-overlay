import Darwin
import Foundation

private enum ResponseTimestampParser {
    private static let lock = NSLock()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let standardFormatter = ISO8601DateFormatter()

    static func parse(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
    }
}

public struct ResponseTokenUsage: Codable, Hashable, Sendable {
    public let inputTokens: Int64?
    public let cachedInputTokens: Int64?
    public let cacheWriteInputTokens: Int64?
    public let outputTokens: Int64?
    public let reasoningOutputTokens: Int64?
    public let totalTokens: Int64?

    public init(
        inputTokens: Int64?,
        cachedInputTokens: Int64?,
        cacheWriteInputTokens: Int64?,
        outputTokens: Int64?,
        reasoningOutputTokens: Int64?,
        totalTokens: Int64?
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

public struct ResponseTokenUsageRecord: Codable, Hashable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let timestamp: String
    public let responseId: String
    public let turnId: String?
    public let sessionId: String?
    public let threadId: String?
    public let model: String
    public let effort: String
    public let usage: ResponseTokenUsage

    public var id: String {
        "\(sessionId ?? "unknown-session"):\(responseId)"
    }

    public var occurredAt: Date? {
        ResponseTimestampParser.parse(timestamp)
    }

    public init(
        schemaVersion: Int = 1,
        timestamp: String,
        responseId: String,
        turnId: String?,
        sessionId: String?,
        threadId: String?,
        model: String,
        effort: String,
        usage: ResponseTokenUsage
    ) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.responseId = responseId
        self.turnId = turnId
        self.sessionId = sessionId
        self.threadId = threadId
        self.model = model
        self.effort = effort
        self.usage = usage
    }

}

public struct ResponseUsageGroup: Hashable, Identifiable, Sendable {
    public let model: String
    public let effort: String
    public let records: [ResponseTokenUsageRecord]

    public var id: String { "\(model)\u{1F}\(effort)" }

    public var totals: ResponseTokenUsage {
        ResponseTokenUsage(
            inputTokens: sum(\.inputTokens),
            cachedInputTokens: sum(\.cachedInputTokens),
            cacheWriteInputTokens: sum(\.cacheWriteInputTokens),
            outputTokens: sum(\.outputTokens),
            reasoningOutputTokens: sum(\.reasoningOutputTokens),
            totalTokens: sum(\.totalTokens)
        )
    }

    public init(model: String, effort: String, records: [ResponseTokenUsageRecord]) {
        self.model = model
        self.effort = effort
        self.records = records
    }

    private func sum(_ keyPath: KeyPath<ResponseTokenUsage, Int64?>) -> Int64? {
        let values = records.compactMap { $0.usage[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}

public enum ResponseUsageGrouping {
    public static func group(
        _ records: [ResponseTokenUsageRecord],
        on day: Date,
        calendar: Calendar = .current
    ) -> [ResponseUsageGroup] {
        let dailyRecords = records.filter { record in
            guard let timestamp = record.occurredAt else { return false }
            return calendar.isDate(timestamp, inSameDayAs: day)
        }
        let grouped = Dictionary(grouping: dailyRecords) {
            "\($0.model)\u{1F}\($0.effort)"
        }
        return grouped.values.compactMap { groupRecords in
            guard let first = groupRecords.first else { return nil }
            return ResponseUsageGroup(model: first.model, effort: first.effort, records: groupRecords.sorted {
                $0.timestamp > $1.timestamp
            })
        }
        .sorted {
            if $0.model != $1.model { return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }
            return $0.effort.localizedCaseInsensitiveCompare($1.effort) == .orderedAscending
        }
    }
}

/// Collects response-level usage from local Codex session files and stores a metadata-only JSONL log.
public final class ResponseUsageLogStore: @unchecked Sendable {
    public static let logFileName = "response-token-usage.jsonl"
    public static let checkpointFileName = "response-token-usage.state.json"

    private struct SourceEnvelope: Decodable {
        let type: String?
        let timestamp: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
            let turnId: String?
            let responseId: String?
            let sessionId: String?
            let threadId: String?
            let model: String?
            let effort: String?
            let usage: UsagePayload?
        }
    }

    private struct UsagePayload: Decodable {
        let inputTokens: Int64?
        let cachedInputTokens: Int64?
        let cacheWriteInputTokens: Int64?
        let outputTokens: Int64?
        let reasoningOutputTokens: Int64?
        let totalTokens: Int64?
    }

    private struct TurnContext: Codable {
        let turnId: String?
        let model: String?
        let effort: String?
    }

    private struct SourceCheckpoint: Codable {
        var offset: UInt64 = 0
        var context: TurnContext?
    }

    private struct Checkpoint: Codable {
        var schemaVersion = 1
        var initialized = false
        var files: [String: SourceCheckpoint] = [:]
    }

    private let codexHomeURL: URL
    private let lock = NSLock()
    private var checkpoint: Checkpoint?
    private var loadedRecords: [ResponseTokenUsageRecord] = []
    private var seenResponseIds = Set<String>()
    private var logReadOffset: UInt64 = 0

    public init(codexHomeURL: URL? = nil) {
        self.codexHomeURL = codexHomeURL ?? Self.defaultCodexHomeURL
    }

    public var logURL: URL {
        codexHomeURL.appendingPathComponent(Self.logFileName)
    }

    /// Scans new source bytes, appends unseen responses, and returns the complete app-owned log.
    @discardableResult
    public func synchronize(now: Date = Date()) throws -> [ResponseTokenUsageRecord] {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(
            at: codexHomeURL,
            withIntermediateDirectories: true
        )
        let lockDescriptor = try acquireFileLock()
        defer {
            releaseFileLock(lockDescriptor)
            _ = Darwin.close(lockDescriptor)
        }

        try loadExistingLogIfNeeded()
        checkpoint = nil // Another app instance may have advanced the shared checkpoint.
        try loadCheckpointIfNeeded()

        let sessionsURL = codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
            return loadedRecords
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let urls = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )?.allObjects.compactMap { $0 as? URL }.sorted { $0.path < $1.path } ?? []
        let calendar = Calendar.current
        let decoder = Self.makeDecoder()
        let shouldBackfillToday = checkpoint?.initialized == false
        var nextCheckpoint = checkpoint ?? Checkpoint()

        for url in urls where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let key = url.standardizedFileURL.path
            var source = nextCheckpoint.files[key] ?? SourceCheckpoint()
            let size = UInt64(values.fileSize ?? 0)
            if size < source.offset {
                source = SourceCheckpoint()
            }
            guard size > source.offset else {
                nextCheckpoint.files[key] = source
                continue
            }

            do {
                let file = try FileHandle(forReadingFrom: url)
                try file.seek(toOffset: source.offset)
                let appended = try file.readToEnd() ?? Data()
                try file.close()

                var lineStart = appended.startIndex
                for newline in appended.indices where appended[newline] == 0x0A {
                    let line = Data(appended[lineStart..<newline])
                    if let envelope = try? decoder.decode(SourceEnvelope.self, from: line) {
                        if envelope.type == "turn_context", let payload = envelope.payload {
                            source.context = TurnContext(
                                turnId: payload.turnId,
                                model: payload.model,
                                effort: payload.effort
                            )
                        } else if envelope.type == "token_usage_record",
                                  let payload = envelope.payload,
                                  let timestamp = envelope.timestamp,
                                  let responseId = payload.responseId,
                                  let usage = payload.usage {
                            let sameTurn = source.context?.turnId == payload.turnId
                            let record = ResponseTokenUsageRecord(
                                timestamp: timestamp,
                                responseId: responseId,
                                turnId: payload.turnId,
                                sessionId: payload.sessionId,
                                threadId: payload.threadId,
                                model: sameTurn ? source.context?.model ?? "unknown" : "unknown",
                                effort: sameTurn ? source.context?.effort ?? "unknown" : "unknown",
                                usage: ResponseTokenUsage(
                                    inputTokens: usage.inputTokens,
                                    cachedInputTokens: usage.cachedInputTokens,
                                    cacheWriteInputTokens: usage.cacheWriteInputTokens,
                                    outputTokens: usage.outputTokens,
                                    reasoningOutputTokens: usage.reasoningOutputTokens,
                                    totalTokens: usage.totalTokens
                                )
                            )
                            let inInitialDay = Self.isSameLocalDay(timestamp, as: now, calendar: calendar)
                            if (!shouldBackfillToday || inInitialDay), !seenResponseIds.contains(record.id) {
                                try append(record)
                            }
                        }
                    }

                    source.offset += UInt64(newline - lineStart) + 1
                    lineStart = appended.index(after: newline)
                }
                nextCheckpoint.files[key] = source
            } catch {
                // Keep this file's prior checkpoint so a later refresh retries it.
                continue
            }
        }

        nextCheckpoint.initialized = true
        try saveCheckpoint(nextCheckpoint)
        checkpoint = nextCheckpoint
        return loadedRecords
    }

    public func records(on day: Date = Date(), calendar: Calendar = .current) -> [ResponseTokenUsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        try? loadExistingLogIfNeeded()
        return loadedRecords.filter { record in
            guard let timestamp = Self.parseTimestamp(record.timestamp) else { return false }
            return calendar.isDate(timestamp, inSameDayAs: day)
        }
    }

    private func append(_ record: ResponseTokenUsageRecord) throws {
        try FileManager.default.createDirectory(
            at: codexHomeURL,
            withIntermediateDirectories: true
        )
        let encoder = Self.makeEncoder()
        var data = try encoder.encode(record)
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } else {
            try data.write(to: logURL, options: .atomic)
        }
        try setPrivatePermissions(for: logURL)
        logReadOffset += UInt64(data.count)
        seenResponseIds.insert(record.id)
        loadedRecords.append(record)
    }

    private func loadExistingLogIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if size < logReadOffset {
            logReadOffset = 0
            loadedRecords.removeAll(keepingCapacity: true)
            seenResponseIds.removeAll(keepingCapacity: true)
        }
        guard size > logReadOffset else {
            return
        }

        let reader = try FileHandle(forReadingFrom: logURL)
        try reader.seek(toOffset: logReadOffset)
        let appended = try reader.readToEnd() ?? Data()
        try reader.close()
        let completeEnd = appended.lastIndex(of: 0x0A).map { appended.index(after: $0) } ?? appended.startIndex
        if completeEnd < appended.endIndex {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.truncate(atOffset: logReadOffset + UInt64(completeEnd))
            try handle.synchronize()
            try handle.close()
        }
        let decoder = Self.makeDecoder()
        for line in appended[..<completeEnd].split(separator: 0x0A) {
            guard let record = try? decoder.decode(ResponseTokenUsageRecord.self, from: Data(line)) else { continue }
            if seenResponseIds.insert(record.id).inserted {
                loadedRecords.append(record)
            }
        }
        logReadOffset += UInt64(completeEnd)
        try setPrivatePermissions(for: logURL)
    }

    private func loadCheckpointIfNeeded() throws {
        let url = codexHomeURL.appendingPathComponent(Self.checkpointFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            checkpoint = Checkpoint()
            return
        }
        do {
            checkpoint = try Self.makeDecoder().decode(Checkpoint.self, from: Data(contentsOf: url))
        } catch {
            checkpoint = Checkpoint()
        }
    }

    private func saveCheckpoint(_ value: Checkpoint) throws {
        try FileManager.default.createDirectory(
            at: codexHomeURL,
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(value)
        let url = codexHomeURL.appendingPathComponent(Self.checkpointFileName)
        try data.write(to: url, options: .atomic)
        try setPrivatePermissions(for: url)
    }

    private func acquireFileLock() throws -> Int32 {
        let url = codexHomeURL.appendingPathComponent("response-token-usage.lock")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var statusLock = Darwin.flock()
        statusLock.l_type = Int16(F_WRLCK)
        statusLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &statusLock) != -1 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private func releaseFileLock(_ descriptor: Int32) {
        var statusLock = Darwin.flock()
        statusLock.l_type = Int16(F_UNLCK)
        statusLock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &statusLock)
    }

    private func setPrivatePermissions(for url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func isSameLocalDay(_ timestamp: String, as date: Date, calendar: Calendar) -> Bool {
        guard let timestamp = parseTimestamp(timestamp) else { return false }
        return calendar.isDate(timestamp, inSameDayAs: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        ResponseTimestampParser.parse(value)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var defaultCodexHomeURL: URL {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
