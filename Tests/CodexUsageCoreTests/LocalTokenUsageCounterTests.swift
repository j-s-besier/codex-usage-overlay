import Foundation
import XCTest
@testable import CodexUsageCore

final class LocalTokenUsageCounterTests: XCTestCase {
    private var codexHome: URL!
    private var sessions: URL!

    override func setUpWithError() throws {
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-token-counter-tests-\(UUID().uuidString)", isDirectory: true)
        sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let codexHome { try? FileManager.default.removeItem(at: codexHome) }
    }

    func testReconciliationThenChangedFileReadsOnlyAppendedBytes() throws {
        let now = Date()
        let file = sessionFile("today.jsonl")
        writeLines([tokenEvent(total: 10, at: now)], to: file)
        let counter = LocalTokenUsageCounter(codexHomeURL: codexHome)

        XCTAssertEqual(try counter.reconcileToday(now: now), 10)
        appendLine(tokenEvent(total: 20, at: now), to: file)
        XCTAssertEqual(try counter.processChangedFiles([file], now: now), 30)
        XCTAssertEqual(try counter.processChangedFiles([file], now: now), 30)
    }

    func testIncompleteLineAndUnrelatedEventDoNotChangeCountUntilCompleted() throws {
        let now = Date()
        let file = sessionFile("partial.jsonl")
        writeLines([tokenEvent(total: 10, at: now)], to: file)
        let counter = LocalTokenUsageCounter(codexHomeURL: codexHome)
        XCTAssertEqual(try counter.reconcileToday(now: now), 10)

        let nextEvent = tokenEvent(total: 20, at: now)
        let splitPoint = nextEvent.count / 2
        appendData(Data(nextEvent.prefix(splitPoint).utf8), to: file)
        XCTAssertEqual(try counter.processChangedFiles([file], now: now), 10)

        appendData(Data((nextEvent.dropFirst(splitPoint) + "\n").utf8), to: file)
        XCTAssertEqual(try counter.processChangedFiles([file], now: now), 30)

        appendData(Data("{\"type\":\"other\"}\n".utf8), to: file)
        XCTAssertEqual(try counter.processChangedFiles([file], now: now), 30)
    }

    func testTruncationAndRemovalSubtractStaleFileTokens() throws {
        let now = Date()
        let first = sessionFile("first.jsonl")
        let second = sessionFile("second.jsonl")
        writeLines([tokenEvent(total: 10, at: now)], to: first)
        writeLines([tokenEvent(total: 20, at: now)], to: second)
        let counter = LocalTokenUsageCounter(codexHomeURL: codexHome)
        XCTAssertEqual(try counter.reconcileToday(now: now), 30)

        writeLines([tokenEvent(total: 5, at: now)], to: first)
        XCTAssertEqual(try counter.processChangedFiles([first], now: now), 25)
        try FileManager.default.removeItem(at: second)
        XCTAssertEqual(try counter.processChangedFiles([second], now: now), 5)
    }

    func testFullReconciliationRebuildsSamePathAfterReplacement() throws {
        let now = Date()
        let file = sessionFile("replace.jsonl")
        writeLines([tokenEvent(total: 10, at: now, padding: String(repeating: "x", count: 300))], to: file)
        let counter = LocalTokenUsageCounter(codexHomeURL: codexHome)
        XCTAssertEqual(try counter.reconcileToday(now: now), 10)

        writeLines([tokenEvent(total: 7, at: now)], to: file)
        XCTAssertEqual(try counter.reconcileToday(now: now), 7)
    }

    func testMidnightReconciliationStartsFreshForNewLocalDay() throws {
        let today = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let file = sessionFile("midnight.jsonl")
        writeLines([tokenEvent(total: 12, at: today)], to: file)
        let counter = LocalTokenUsageCounter(codexHomeURL: codexHome)
        XCTAssertEqual(try counter.reconcileToday(now: today), 12)

        writeLines([tokenEvent(total: 4, at: tomorrow)], to: file)
        try FileManager.default.setAttributes([.modificationDate: tomorrow], ofItemAtPath: file.path)
        XCTAssertEqual(try counter.reconcileToday(now: tomorrow), 4)
    }

    func testCsvWriteThrottleRemainsFiveMinutes() throws {
        let now = Date()
        let file = sessionFile("csv.jsonl")
        writeLines([tokenEvent(total: 10, at: now)], to: file)
        let counter = LocalTokenUsageCounter(codexHomeURL: codexHome)
        XCTAssertEqual(try counter.reconcileToday(now: now), 10)
        let csvURL = codexHome.appendingPathComponent("daily-token-usage.csv")
        let firstCSV = try String(contentsOf: csvURL, encoding: .utf8)

        appendLine(tokenEvent(total: 5, at: now.addingTimeInterval(60)), to: file)
        XCTAssertEqual(try counter.processChangedFiles([file], now: now.addingTimeInterval(60)), 15)
        XCTAssertEqual(try String(contentsOf: csvURL, encoding: .utf8), firstCSV)

        appendLine(tokenEvent(total: 2, at: now.addingTimeInterval(301)), to: file)
        XCTAssertEqual(try counter.processChangedFiles([file], now: now.addingTimeInterval(301)), 17)
        XCTAssertNotEqual(try String(contentsOf: csvURL, encoding: .utf8), firstCSV)
    }

    private func sessionFile(_ name: String) -> URL {
        sessions.appendingPathComponent(name)
    }

    private func tokenEvent(total: Int, at date: Date, padding: String = "") -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let escapedPadding = padding.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: date))\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(total)}}},\"padding\":\"\(escapedPadding)\"}"
    }

    private func writeLines(_ lines: [String], to url: URL) {
        var data = Data(lines.joined(separator: "\n").utf8)
        data.append(0x0A)
        try! data.write(to: url, options: .atomic)
    }

    private func appendLine(_ line: String, to url: URL) {
        appendData(Data((line + "\n").utf8), to: url)
    }

    private func appendData(_ data: Data, to url: URL) {
        let handle = try! FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try! handle.seekToEnd()
        try! handle.write(contentsOf: data)
    }
}
