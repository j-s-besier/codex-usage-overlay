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
        usage?.stop()
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

        let tokenText = usage.displayedDailyTokens.map(TokenCountFormatter.compact) ?? "—"
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
    @Published private(set) var displayedDailyTokens: Int64?
    @Published private(set) var responseRecords: [ResponseTokenUsageRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var logOpenError: String?
    @Published private(set) var responseLogError: String?

    private var timer: Timer?
    private var midnightTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var tokenWatcher: SessionLogChangeWatcher?
    private var dailyTokenAnimationTask: Task<Void, Never>?
    private var dailyTokenDay: Date?
    private let tokenCounter = LocalTokenUsageCounter()
    private let responseLog = ResponseUsageLogStore()
    private var responseInspectorWindow: NSWindow?

    init() {
        startTokenWatcherIfPossible()
        refreshUsage(forceTokenReconciliation: false)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUsage(forceTokenReconciliation: false) }
        }
        scheduleMidnightReconciliation()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDailyTokenTotal(reconcile: true) }
        }
    }

    func refresh() {
        refreshUsage(forceTokenReconciliation: true)
    }

    private func refreshUsage(forceTokenReconciliation: Bool) {
        startTokenWatcherIfPossible()
        if forceTokenReconciliation || tokenWatcher == nil {
            refreshDailyTokenTotal(reconcile: true)
        }
        guard !isLoading else { return }
        isLoading = true
        let responseLog = self.responseLog

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let responseResult = Result { try responseLog.synchronize() }
            let result = Result { try CodexUsageClient.fetch() }
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
                case .failure:
                    self.windows = []
                }
            }
        }
    }

    func flushTokenTotal() {
        tokenCounter.flushLatestTotal()
    }

    func stop() {
        timer?.invalidate()
        midnightTimer?.invalidate()
        dailyTokenAnimationTask?.cancel()
        tokenWatcher?.stop()
        tokenWatcher = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        flushTokenTotal()
    }

    private func startTokenWatcherIfPossible() {
        guard tokenWatcher == nil else { return }
        let watcher = SessionLogChangeWatcher(rootURL: tokenCounter.sessionsDirectoryURL) { [weak self] batch in
            Task { @MainActor in self?.handleTokenFileChanges(batch) }
        }
        guard watcher.start() else { return }
        tokenWatcher = watcher
        refreshDailyTokenTotal(reconcile: true)
    }

    private func handleTokenFileChanges(_ batch: SessionLogChangeWatcher.ChangeBatch) {
        guard batch.requiresReconciliation || !batch.changedFiles.isEmpty else { return }
        if batch.rootWasChanged {
            tokenWatcher?.stop()
            tokenWatcher = nil
            startTokenWatcherIfPossible()
        }
        refreshDailyTokenTotal(
            reconcile: batch.requiresReconciliation,
            changedFiles: batch.changedFiles
        )
    }

    private func refreshDailyTokenTotal(reconcile: Bool, changedFiles: [URL] = []) {
        let tokenCounter = self.tokenCounter
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = Date()
            let result = Result {
                if reconcile {
                    return try tokenCounter.reconcileToday(now: now)
                }
                return try tokenCounter.processChangedFiles(changedFiles, now: now)
            }
            DispatchQueue.main.async {
                guard let self, case .success(let total) = result else { return }
                self.updateDailyTokens(total, for: Calendar.current.startOfDay(for: now))
            }
        }
    }

    private func scheduleMidnightReconciliation() {
        midnightTimer?.invalidate()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let nextMidnight = calendar.date(byAdding: .day, value: 1, to: today) else { return }
        let timer = Timer(fire: nextMidnight, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDailyTokenTotal(reconcile: true)
                self.scheduleMidnightReconciliation()
            }
        }
        midnightTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateDailyTokens(_ total: Int64?, for day: Date) {
        dailyTokens = total
        guard let total else {
            dailyTokenAnimationTask?.cancel()
            displayedDailyTokens = nil
            dailyTokenDay = day
            return
        }

        let isFirstValue = displayedDailyTokens == nil
        let isNewDay = dailyTokenDay != nil && dailyTokenDay != day
        dailyTokenDay = day

        guard !isFirstValue, !isNewDay, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            dailyTokenAnimationTask?.cancel()
            displayedDailyTokens = total
            return
        }

        guard displayedDailyTokens != total else { return }
        dailyTokenAnimationTask?.cancel()
        let startValue = displayedDailyTokens ?? total
        dailyTokenAnimationTask = Task { @MainActor [weak self] in
            let startTime = ProcessInfo.processInfo.systemUptime
            let duration: TimeInterval = 0.25

            while !Task.isCancelled {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self?.displayedDailyTokens = total
                    return
                }

                let progress = min(1, (ProcessInfo.processInfo.systemUptime - startTime) / duration)
                let interpolated = Double(startValue) + (Double(total) - Double(startValue)) * progress
                self?.displayedDailyTokens = Int64(interpolated.rounded())
                if progress >= 1 { return }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
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
}

private enum CodexUsageClient {
    static func fetch() throws -> UsageSnapshot {
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
        return UsageSnapshot(windows: windows)
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
                if let dailyTokens = usage.displayedDailyTokens {
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

private enum InspectorPalette {
    static let input = Color(red: 0.525, green: 0.839, blue: 0.608)
    static let output = Color(red: 0.949, green: 0.545, blue: 0.510)
    static let total = Color(red: 0.569, green: 0.722, blue: 1.0)
    static let other = Color(red: 0.902, green: 0.804, blue: 0.471)

    static func effort(_ raw: String) -> Color {
        switch raw.lowercased() {
        case "low": return output
        case "medium": return Color(red: 0.953, green: 0.667, blue: 0.439)
        case "high": return Color(red: 0.824, green: 0.851, blue: 0.502)
        case "xhigh", "extra high", "max", "ultra": return input
        default: return .secondary
        }
    }

    static func effortLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "xhigh", "extra high": return "Extra high"
        case "", "unknown": return "Unknown"
        default: return raw.capitalized
        }
    }
}

private enum InspectorMode: String, CaseIterable, Identifiable {
    case responses = "Responses", model = "Model", session = "Session"
    var id: String { rawValue }
}

private struct InspectorPresentationSnapshot: Sendable {
    var records: [ResponseTokenUsageRecord] = []
    var models: [ResponseModelSummary] = []
    var sessions: [ResponseSessionSummary] = []
}

private struct ResponseUsageInspectorView: View {
    @ObservedObject var usage: UsageStore
    @State private var selectedDay = Date()
    @State private var mode: InspectorMode = .responses
    @State private var sourceRevision = 0
    @State private var isPreparing = true
    @State private var snapshot = InspectorPresentationSnapshot()

    private var preparationKey: String {
        "\(sourceRevision):\(selectedDay.timeIntervalSinceReferenceDate)"
    }

    private var records: [ResponseTokenUsageRecord] {
        snapshot.records
    }

    private var countLabel: String {
        if mode == .model {
            return "\(snapshot.models.count.formatted()) models used"
        }
        return "\(records.count.formatted()) responses · newest first"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Response token usage").font(.system(size: 18, weight: .semibold))
                    Text("Local response usage by response, model, or session")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                DatePicker("Day", selection: $selectedDay, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).frame(width: 120)
            }
            Divider()
            HStack {
                Text(countLabel)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("Group by", selection: $mode) {
                    ForEach(InspectorMode.allCases) { value in Text(value.rawValue).tag(value) }
                }
                .pickerStyle(.segmented).frame(width: 270)
            }
            if isPreparing {
                ProgressView("Preparing response usage…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No response usage logged for this day").font(.system(size: 13, weight: .medium))
                    Text("The app records usage from local Codex session files while Codex is running.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    switch mode {
                    case .responses:
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(records) { ResponseUsageRow(record: $0, showsModel: true) }
                        }
                    case .model:
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(snapshot.models) { ModelUsageRow(model: $0) }
                        }
                    case .session:
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(snapshot.sessions) { session in
                                DisclosureGroup {
                                    LazyVStack(alignment: .leading, spacing: 7) {
                                        ForEach(session.threads) { thread in
                                            DisclosureGroup {
                                                LazyVStack(alignment: .leading, spacing: 0) {
                                                    ForEach(thread.records) { ResponseUsageRow(record: $0, showsModel: true) }
                                                }
                                            } label: {
                                                UsageGroupLabel(name: thread.id, detail: "\(thread.records.count) responses", total: thread.totals.total)
                                            }
                                            .padding(8)
                                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                                        }
                                    }.padding(.leading, 8)
                                } label: {
                                    UsageGroupLabel(name: session.displayName,
                                        detail: "\(session.threads.count) threads · \(session.records.count) responses",
                                        total: session.totals.total)
                                }
                                .padding(10)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 500)
        .onChange(of: usage.responseRecords) { _ in sourceRevision += 1 }
        .task(id: preparationKey) {
            isPreparing = true
            let sourceRecords = usage.responseRecords
            let day = selectedDay
            let prepared = await Task.detached(priority: .userInitiated) {
                let records = ResponseUsagePresentation.responses(sourceRecords, on: day)
                let models = ResponseUsagePresentation.models(records)
                let sessions = ResponseUsagePresentation.sessions(records, names: SessionIndexNames.read())
                return InspectorPresentationSnapshot(records: records, models: models, sessions: sessions)
            }.value
            guard !Task.isCancelled else { return }
            snapshot = prepared
            isPreparing = false
        }
    }
}

private struct UsageGroupLabel: View {
    let name: String
    let detail: String
    let total: Int64?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(total?.formatted() ?? "—").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(InspectorPalette.total)
                Text("Total tokens").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ModelUsageRow: View {
    let model: ResponseModelSummary
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.capabilityListAvailable {
                    Text("Supported effort list unavailable; showing observed usage")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ForEach(model.efforts) { effort in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(effort.label).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(InspectorPalette.effort(effort.id))
                        HStack(spacing: 4) {
                            metric("Input", effort.totals.input, color: InspectorPalette.input)
                            metric("Output", effort.totals.output, color: InspectorPalette.output)
                            metric("Total", effort.totals.total, color: InspectorPalette.total)
                        }
                    }
                    if effort.id != model.efforts.last?.id { Divider() }
                }
            }
            .padding(.top, 7)
            .padding(.bottom, 5)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(model.records.count.formatted()) responses · \(model.efforts.count.formatted()) efforts")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.totals.total?.formatted() ?? "—")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(InspectorPalette.total)
                    Text("Total tokens").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(expanded ? "Show less" : "Show more")
                    .font(.system(size: 10)).foregroundStyle(.purple).fixedSize()
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func metric(_ label: String, _ value: Int64?, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value?.formatted() ?? "—").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ResponseUsageRow: View {
    let record: ResponseTokenUsageRecord
    let showsModel: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.responseId).font(.system(size: 11, design: .monospaced))
                .lineLimit(1).textSelection(.enabled)
            HStack(spacing: 6) {
                Text(record.occurredAt?.formatted(date: .omitted, time: .standard) ?? record.timestamp)
                if showsModel { Text(record.model) }
                Text("· \(InspectorPalette.effortLabel(record.effort))")
                    .foregroundStyle(InspectorPalette.effort(record.effort))
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                token("Input", record.usage.inputTokens, color: InspectorPalette.input)
                token("Output", record.usage.outputTokens, color: InspectorPalette.output)
                token("Total", record.usage.totalTokens, color: InspectorPalette.total)
                Spacer(minLength: 0)
                Button(expanded ? "Less info" : "More info") { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.purple)
                    .accessibilityLabel(expanded ? "Hide response details" : "Show response details")
            }
            if expanded {
                HStack(spacing: 13) {
                    token("Cached input", record.usage.cachedInputTokens, color: InspectorPalette.other)
                    token("Cache write input", record.usage.cacheWriteInputTokens, color: InspectorPalette.other)
                    token("Reasoning output", record.usage.reasoningOutputTokens, color: InspectorPalette.other)
                }
                .font(.system(size: 10))
                Text("Session \(record.sessionId ?? "—") · Thread \(record.threadId ?? "—")")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func token(_ label: String, _ value: Int64?, color: Color) -> some View {
        Text("\(label) \(value?.formatted() ?? "—")")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .accessibilityLabel("\(label) tokens, \(value?.formatted() ?? "unavailable")")
    }
}
