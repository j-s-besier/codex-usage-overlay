import Foundation
import XCTest
@testable import CodexUsageCore

final class ResponseUsageLogStoreTests: XCTestCase {
    private var codexHome: URL!

    override func setUpWithError() throws {
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("response-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: codexHome.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let codexHome { try? FileManager.default.removeItem(at: codexHome) }
    }

    func testRecordsPerResponseUsageAndMatchingTurnContextOnly() throws {
        let now = Date()
        let file = sessionFile("response.jsonl")
        try writeLines([
            turnContext(turnId: "turn-a", model: "gpt-6-luna", effort: "medium"),
            usageRecord(responseId: "response-a", turnId: "turn-a", timestamp: timestamp(now), total: 120),
            usageRecord(responseId: "response-b", turnId: "turn-a", timestamp: timestamp(now), total: 80, turnTotal: 200)
        ], to: file)

        let store = ResponseUsageLogStore(codexHomeURL: codexHome)
        let records = try store.synchronize(now: now)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.responseId), ["response-a", "response-b"])
        XCTAssertEqual(records.map(\.model), ["gpt-6-luna", "gpt-6-luna"])
        XCTAssertEqual(records.map(\.effort), ["medium", "medium"])
        XCTAssertEqual(records.map { $0.usage.totalTokens }, [120, 80])
        XCTAssertEqual(records[0].usage.inputTokens, 100)
        XCTAssertEqual(records[0].usage.cachedInputTokens, 60)
        XCTAssertEqual(records[0].usage.outputTokens, 20)
        XCTAssertEqual(records[0].usage.reasoningOutputTokens, 9)
        let groups = ResponseUsageGrouping.group(records, on: now)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].model, "gpt-6-luna")
        XCTAssertEqual(groups[0].effort, "medium")
        XCTAssertEqual(groups[0].records.count, 2)
        XCTAssertEqual(groups[0].totals.totalTokens, 200)
        XCTAssertEqual(groups[0].totals.cachedInputTokens, 120)
        XCTAssertEqual(groups[0].totals.reasoningOutputTokens, 18)

        let saved = try String(contentsOf: store.logURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("private message text"))
        XCTAssertEqual(saved.split(whereSeparator: \.isNewline).count, 2)
    }

    func testUnknownContextDoesNotDiscardResponse() throws {
        let now = Date()
        try writeLines([
            usageRecord(responseId: "response-no-context", turnId: "missing", timestamp: timestamp(now), total: 7)
        ], to: sessionFile("unknown.jsonl"))

        let records = try ResponseUsageLogStore(codexHomeURL: codexHome).synchronize(now: now)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].model, "unknown")
        XCTAssertEqual(records[0].effort, "unknown")
    }

    func testFirstRunImportsOnlyTodayThenRestartCatchesUpWithoutDuplicates() throws {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let file = sessionFile("catch-up.jsonl")
        try writeLines([
            turnContext(turnId: "turn-a", model: "gpt-6-sol", effort: "high"),
            usageRecord(responseId: "old", turnId: "turn-a", timestamp: timestamp(yesterday), total: 5),
            usageRecord(responseId: "today", turnId: "turn-a", timestamp: timestamp(now), total: 10)
        ], to: file)

        let firstStore = ResponseUsageLogStore(codexHomeURL: codexHome)
        XCTAssertEqual(try firstStore.synchronize(now: now).map(\.responseId), ["today"])
        XCTAssertEqual(try firstStore.synchronize(now: now).count, 1)

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        appendLine(usageRecord(responseId: "after-restart", turnId: "turn-a", timestamp: timestamp(tomorrow), total: 12), to: file)

        let restartedStore = ResponseUsageLogStore(codexHomeURL: codexHome)
        let caughtUp = try restartedStore.synchronize(now: tomorrow)
        XCTAssertEqual(caughtUp.map(\.responseId), ["today", "after-restart"])
        XCTAssertEqual(try restartedStore.synchronize(now: tomorrow).count, 2)

        let saved = try String(contentsOf: restartedStore.logURL, encoding: .utf8)
        XCTAssertEqual(saved.split(whereSeparator: \.isNewline).count, 2)
    }

    func testIncompleteTrailingLineIsRetriedWhenCompleted() throws {
        let now = Date()
        let file = sessionFile("partial.jsonl")
        appendLine(turnContext(turnId: "turn-p", model: "gpt-6-luna", effort: "low"), to: file)
        let partial = usageRecord(responseId: "partial-response", turnId: "turn-p", timestamp: timestamp(now), total: 14)
        try FileHandle(forWritingTo: file).run { handle in
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(partial.prefix(partial.count / 2).utf8))
        }

        let store = ResponseUsageLogStore(codexHomeURL: codexHome)
        XCTAssertTrue(try store.synchronize(now: now).isEmpty)

        try FileHandle(forWritingTo: file).run { handle in
            try handle.seekToEnd()
            var remainder = Data(partial.dropFirst(partial.count / 2).utf8)
            remainder.append(0x0A)
            try handle.write(contentsOf: remainder)
        }
        XCTAssertEqual(try store.synchronize(now: now).map(\.responseId), ["partial-response"])
    }

    func testTruncatedSourceFileIsRescannedAndDuplicateIsSkipped() throws {
        let now = Date()
        let file = sessionFile("truncate.jsonl")
        let longContext = turnContext(turnId: "turn-a", model: "gpt-6-sol", effort: "medium", padding: String(repeating: "x", count: 300))
        try writeLines([
            longContext,
            usageRecord(responseId: "first", turnId: "turn-a", timestamp: timestamp(now), total: 3)
        ], to: file)
        let store = ResponseUsageLogStore(codexHomeURL: codexHome)
        XCTAssertEqual(try store.synchronize(now: now).count, 1)

        try writeLines([
            usageRecord(responseId: "first", turnId: "turn-a", timestamp: timestamp(now), total: 3)
        ], to: file)
        XCTAssertEqual(try store.synchronize(now: now).count, 1)
    }

    func testPartialOwnedLogTailIsRepairedBeforeAppending() throws {
        let now = Date()
        try writeLines([
            turnContext(turnId: "turn-a", model: "gpt-6-luna", effort: "medium"),
            usageRecord(responseId: "response-a", turnId: "turn-a", timestamp: timestamp(now), total: 10)
        ], to: sessionFile("owned-tail.jsonl"))
        let ownedLog = codexHome.appendingPathComponent(ResponseUsageLogStore.logFileName)
        try Data("{\"incomplete\":".utf8).write(to: ownedLog)

        let store = ResponseUsageLogStore(codexHomeURL: codexHome)
        let records = try store.synchronize(now: now)
        XCTAssertEqual(records.map(\.responseId), ["response-a"])
        XCTAssertEqual(try String(contentsOf: ownedLog, encoding: .utf8).split(whereSeparator: \.isNewline).count, 1)
    }

    func testSeparateCollectorsReloadNewRowsAndSharedCheckpoint() throws {
        let now = Date()
        let file = sessionFile("two-collectors.jsonl")
        try writeLines([
            turnContext(turnId: "turn-a", model: "gpt-6-sol", effort: "high"),
            usageRecord(responseId: "first", turnId: "turn-a", timestamp: timestamp(now), total: 10)
        ], to: file)
        let first = ResponseUsageLogStore(codexHomeURL: codexHome)
        XCTAssertEqual(try first.synchronize(now: now).count, 1)

        appendLine(usageRecord(responseId: "second", turnId: "turn-a", timestamp: timestamp(now), total: 20), to: file)
        let second = ResponseUsageLogStore(codexHomeURL: codexHome)
        XCTAssertEqual(try second.synchronize(now: now).count, 2)
        XCTAssertEqual(try first.synchronize(now: now).count, 2)

        let saved = try String(contentsOf: first.logURL, encoding: .utf8)
        XCTAssertEqual(saved.split(whereSeparator: \.isNewline).count, 2)
    }

    private func sessionFile(_ name: String) -> URL {
        codexHome.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(name)
    }

    private func writeLines(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendLine(_ line: String, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        try? handle.close()
    }

    private func turnContext(turnId: String, model: String, effort: String, padding: String? = nil) -> String {
        var payload: [String: Any] = ["turn_id": turnId, "model": model, "effort": effort]
        if let padding { payload["padding"] = padding }
        return json(["type": "turn_context", "payload": payload])
    }

    private func usageRecord(
        responseId: String,
        turnId: String,
        timestamp: String,
        total: Int,
        turnTotal: Int? = nil
    ) -> String {
        let totalUsage = turnTotal ?? total
        return json([
            "type": "token_usage_record",
            "timestamp": timestamp,
            "payload": [
                "response_id": responseId,
                "turn_id": turnId,
                "session_id": "session-test",
                "thread_id": "thread-test",
                "usage": [
                    "input_tokens": total - 20,
                    "cached_input_tokens": 60,
                    "cache_write_input_tokens": 4,
                    "output_tokens": 20,
                    "reasoning_output_tokens": 9,
                    "total_tokens": total
                ],
                "turn_token_usage": ["total_tokens": totalUsage],
                "thread_token_usage": ["total_tokens": 9999]
            ]
        ])
    }

    private func json(_ value: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension FileHandle {
    func run(_ body: (FileHandle) throws -> Void) throws {
        defer { try? close() }
        try body(self)
    }
}
