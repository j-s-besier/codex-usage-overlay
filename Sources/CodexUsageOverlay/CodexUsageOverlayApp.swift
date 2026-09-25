import AppKit
import Combine
import CodexUsageCore
import SwiftUI

@main
struct CodexUsageOverlayApp: App {
    @NSApplicationDelegateAdaptor(OverlayAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class OverlayAppDelegate: NSObject, NSApplicationDelegate {
    private var usage: UsageStore!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var usageObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        usage = UsageStore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 270, height: 260)
        popover.contentViewController = NSHostingController(rootView: UsagePopoverView(usage: usage))

        usageObserver = usage.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        usage?.flushTokenTotal()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)

        let tokenText = usage.dailyTokens.map(TokenCountFormatter.compact) ?? "—"
        title.append(NSAttributedString(string: tokenText, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]))
        title.append(NSAttributedString(string: " · ", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]))

        if let primary = usage.windows.first {
            title.append(NSAttributedString(string: "\(primary.remainingPercent)%", attributes: [
                .font: font,
                .foregroundColor: primary.statusBarColor
            ]))
        } else {
            let text = usage.isLoading && !usage.hasLoaded ? "…" : "—"
            title.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        button.attributedTitle = title
        button.toolTip = "Today's Codex tokens and remaining usage limit"
    }

}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var windows: [UsageWindow] = []
    @Published private(set) var dailyTokens: Int64?
    @Published private(set) var responseRecords: [ResponseTokenUsageRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var logOpenError: String?
    @Published private(set) var responseLogError: String?

    private var timer: Timer?
    private let tokenCounter = LocalTokenUsageCounter()
    private let responseLog = ResponseUsageLogStore()
    private var responseInspectorWindow: NSWindow?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let tokenCounter = self.tokenCounter
        let responseLog = self.responseLog

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let responseResult = Result { try responseLog.synchronize() }
            let result = Result {
                try CodexUsageClient.fetch(dailyTokens: try? tokenCounter.todayTotal())
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.hasLoaded = true
                switch responseResult {
                case .success(let records):
                    if self.responseRecords != records {
                        self.responseRecords = records
                    }
                    self.responseLogError = nil
                case .failure(let error):
                    self.responseLogError = "Couldn't update response log: \(error.localizedDescription)"
                }
                switch result {
                case .success(let snapshot):
                    self.windows = snapshot.windows
                    self.dailyTokens = snapshot.dailyTokens
                case .failure:
                    self.windows = []
                    self.dailyTokens = nil
                }
            }
        }
    }

    func flushTokenTotal() {
        tokenCounter.flushLatestTotal()
    }

    func openDailyLog() {
        logOpenError = nil
        do {
            let url = try tokenCounter.prepareDailyLogForViewing()
            guard NSWorkspace.shared.open(url) else {
                logOpenError = "macOS couldn't open the CSV file."
                return
            }
        } catch {
            logOpenError = "Couldn't prepare the CSV file: \(error.localizedDescription)"
        }
    }

    func openResponseInspector() {
        if let window = responseInspectorWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Response Token Usage"
        window.contentViewController = NSHostingController(rootView: ResponseUsageInspectorView(usage: self))
        window.isReleasedWhenClosed = false
        window.center()
        responseInspectorWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct UsageWindow: Identifiable {
    let id: String
    let remainingPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var durationLabel: String {
        guard let durationMinutes, durationMinutes > 0 else { return "usage" }
        if durationMinutes < 60 { return "\(durationMinutes)m" }
        if durationMinutes < 24 * 60 { return "\(durationMinutes / 60)h" }
        return "\(durationMinutes / (24 * 60))d"
    }

    var resetLabel: String? {
        guard let resetsAt else { return nil }
        let seconds = max(0, Int(resetsAt.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(max(1, minutes))m"
    }

    var tint: Color {
        if remainingPercent > 50 { return .green }
        if remainingPercent >= 20 { return .yellow }
        return .red
    }

    var statusBarColor: NSColor {
        if remainingPercent > 50 { return .systemGreen }
        if remainingPercent >= 20 { return .systemYellow }
        return .systemRed
    }
}

private struct RateWindowPayload: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
}

private struct RateBucketPayload: Decodable {
    let primary: RateWindowPayload?
    let secondary: RateWindowPayload?
}

private struct RateLimitsPayload: Decodable {
    let rateLimits: RateBucketPayload?
    let rateLimitsByLimitId: [String: RateBucketPayload]?
}

private struct UsageSnapshot {
    let windows: [UsageWindow]
    let dailyTokens: Int64?
}

private enum CodexUsageClient {
    static func fetch(dailyTokens: Int64?) throws -> UsageSnapshot {
        let executable = try codexExecutablePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let reader = JSONLineReader(handle: output.fileHandleForReading)
        try send(["method": "initialize", "id": 1, "params": [
            "clientInfo": ["name": "codex-usage-overlay", "title": "Codex Usage Overlay", "version": "0.1.0"]
        ]], to: input)
        _ = try response(id: 1, from: reader)

        try send(["method": "initialized", "params": [:]], to: input)
        try send(["method": "account/rateLimits/read", "id": 2], to: input)
        let response = try response(id: 2, from: reader)

        if let error = response["error"] as? [String: Any] {
            throw UsageError.server(error["message"] as? String ?? "Codex App Server returned an error")
        }
        guard let result = response["result"] else {
            throw UsageError.invalidResponse
        }

        let data = try JSONSerialization.data(withJSONObject: result)
        let payload = try JSONDecoder().decode(RateLimitsPayload.self, from: data)
        let bucket = payload.rateLimitsByLimitId?["codex"] ?? payload.rateLimits
        guard let bucket else { throw UsageError.noCodexLimit }

        let windows: [UsageWindow] = [bucket.primary, bucket.secondary]
            .enumerated()
            .compactMap { index, window in
                guard let window, let used = window.usedPercent else { return nil }
                return UsageWindow(
                    id: index == 0 ? "primary" : "secondary",
                    remainingPercent: max(0, min(100, 100 - Int(used.rounded()))),
                    durationMinutes: window.windowDurationMins,
                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))
                )
            }
        return UsageSnapshot(windows: windows, dailyTokens: dailyTokens)
    }

    private static func codexExecutablePath() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["CODEX_CLI_PATH"], "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .compactMap { $0 }
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(directory)/codex"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw UsageError.codexNotFound
    }

    private static func send(_ message: [String: Any], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        var line = data
        line.append(0x0A)
        try pipe.fileHandleForWriting.write(contentsOf: line)
    }

    private static func response(id: Int, from reader: JSONLineReader) throws -> [String: Any] {
        while let message = try reader.readMessage() {
            if (message["id"] as? Int) == id { return message }
        }
        throw UsageError.server("Codex App Server closed the connection")
    }
}

private final class JSONLineReader {
    private let handle: FileHandle
    private var buffered = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readMessage() throws -> [String: Any]? {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                let line = buffered.prefix(upTo: newline)
                buffered.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                return try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }

            let byte = try handle.read(upToCount: 1) ?? Data()
            guard !byte.isEmpty else { return nil }
            buffered.append(byte)
        }
    }
}

private enum UsageError: Error {
    case codexNotFound
    case invalidResponse
    case noCodexLimit
    case server(String)
}

struct UsagePopoverView: View {
    @ObservedObject var usage: UsageStore

    private var primary: UsageWindow? { usage.windows.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
            Circle()
                .fill(primary?.tint ?? (usage.hasLoaded ? .secondary : .gray))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                if let primary {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(primary.remainingPercent)% left")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text(primary.durationLabel)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    if let resetLabel = primary.resetLabel {
                        Text(resetLabel)
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } else if usage.isLoading && !usage.hasLoaded {
                    Text("Loading usage…")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                } else {
                    Text("Usage unavailable")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                    Text("Check Codex sign-in")
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(action: usage.refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Refresh usage now")
            }

            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Tokens today")
                    .foregroundStyle(.secondary)
                Spacer()
                if let dailyTokens = usage.dailyTokens {
                    Text(dailyTokens.formatted())
                        .fontWeight(.semibold)
                } else {
                    Text("Not reported yet")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))

            HStack {
                Text("Daily log")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    usage.openDailyLog()
                } label: {
                    Label("Open CSV", systemImage: "doc.text.magnifyingglass")
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open the daily token history CSV")
            }

            HStack {
                Text("Response log")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    usage.openResponseInspector()
                } label: {
                    Label("Inspect", systemImage: "chart.bar.doc.horizontal")
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Inspect response token usage by model and effort")
            }

            if let logOpenError = usage.logOpenError {
                Text(logOpenError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let responseLogError = usage.responseLogError {
                Text(responseLogError)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let secondary = usage.windows.dropFirst().first {
                HStack {
                    Text("Longer window")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(secondary.remainingPercent)% left · \(secondary.durationLabel)")
                        .fontWeight(.medium)
                }
                .font(.system(size: 11))
                if let resetLabel = secondary.resetLabel {
                    Text(resetLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if usage.isLoading {
                Text("Updating…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 270)
    }
}

private struct ResponseUsageInspectorView: View {
    @ObservedObject var usage: UsageStore
    @State private var selectedDay = Date()

    private var dayRecords: [ResponseTokenUsageRecord] {
        usage.responseRecords
            .filter { record in
                guard let date = record.occurredAt else { return false }
                return Calendar.current.isDate(date, inSameDayAs: selectedDay)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var groups: [ResponseUsageGroup] {
        ResponseUsageGrouping.group(usage.responseRecords, on: selectedDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Response token usage")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Local token metadata grouped by model and reasoning effort")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DatePicker("Day", selection: $selectedDay, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(width: 120)
            }

            Divider()

            if dayRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No response usage logged for this day")
                        .font(.system(size: 13, weight: .medium))
                    Text("The app records usage from local Codex session files while Codex is running.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("\(dayRecords.count.formatted()) responses")
                    Spacer()
                    Text("\(groups.count.formatted()) model/effort groups")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groups) { group in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(group.records) { record in
                                        ResponseUsageRow(record: record)
                                        if record.id != group.records.last?.id {
                                            Divider().padding(.leading, 8)
                                        }
                                    }
                                }
                                .padding(.leading, 8)
                            } label: {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(group.model)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text("effort: \(group.effort) · \(group.records.count.formatted()) responses")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(group.totals.totalTokens.map { $0.formatted() } ?? "—")
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        Text("total tokens")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 5)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 500)
    }
}

private struct ResponseUsageRow: View {
    let record: ResponseTokenUsageRecord

    private var timeLabel: String {
        record.occurredAt?.formatted(date: .omitted, time: .standard) ?? record.timestamp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(timeLabel)
                    .font(.system(size: 11, weight: .medium))
                Text("response \(record.responseId)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Text("\(record.usage.totalTokens?.formatted() ?? "—") tokens")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            HStack(spacing: 12) {
                Text("Input \(display(record.usage.inputTokens))")
                Text("Cached \(display(record.usage.cachedInputTokens))")
                Text("Cache write \(display(record.usage.cacheWriteInputTokens))")
            }
            HStack(spacing: 12) {
                Text("Output \(display(record.usage.outputTokens))")
                Text("Reasoning \(display(record.usage.reasoningOutputTokens))")
                Text("Total \(display(record.usage.totalTokens))")
            }
            HStack(spacing: 12) {
                if let sessionId = record.sessionId { Text("Session \(sessionId)") }
                if let threadId = record.threadId { Text("Thread \(threadId)") }
            }
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
        .font(.system(size: 10))
        .padding(.vertical, 8)
    }

    private func display(_ value: Int64?) -> String {
        value?.formatted() ?? "—"
    }
}
