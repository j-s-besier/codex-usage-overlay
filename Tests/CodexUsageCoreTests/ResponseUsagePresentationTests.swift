import Foundation
import XCTest
@testable import CodexUsageCore

final class ResponseUsagePresentationTests: XCTestCase {
    private let day = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDayFilteringAndNewestFirstWithoutBreakdownDoubleCounting() {
        let records = [
            record("early", "2026-09-25T10:00:00Z", session: "s", thread: "a", total: 30),
            record("later", "2026-09-25T11:00:00Z", session: "s", thread: "a", total: 50),
            record("other-day", "2026-09-24T11:00:00Z", session: "s", thread: "a", total: 90)
        ]
        let daily = ResponseUsagePresentation.responses(records, on: day, calendar: utc)
        XCTAssertEqual(daily.map(\.responseId), ["later", "early"])
        XCTAssertEqual(ResponseUsagePresentation.models(daily)[0].totals.total, 80)
        XCTAssertEqual(ResponseUsagePresentation.sessions(daily)[0].totals.total, 80)
        XCTAssertEqual(ResponseUsagePresentation.models(daily)[0].totals.input, 40)
    }

    func testKnownModelOrdersSupportedEffortsAndAddsZeroRows() {
        let models = ResponseUsagePresentation.models([
            record("one", "2026-09-25T10:00:00Z", model: "gpt-6-luna", effort: "medium")
        ])
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].displayName, "GPT-6 Luna")
        XCTAssertTrue(models[0].capabilityListAvailable)
        XCTAssertEqual(models[0].efforts.map(\.id), ["max", "xhigh", "high", "medium", "low"])
        XCTAssertEqual(models[0].efforts[0].totals, ResponseUsageTotals(records: []))
        XCTAssertEqual(models[0].efforts.first { $0.id == "medium" }?.totals.total, 30)
    }

    func testUnknownEffortsAndUnlistedModel() {
        let models = ResponseUsagePresentation.models([
            record("one", "2026-09-25T10:00:00Z", model: "future-model", effort: "high"),
            record("two", "2026-09-25T11:00:00Z", model: "future-model", effort: "future-effort")
        ])
        XCTAssertFalse(models[0].capabilityListAvailable)
        XCTAssertEqual(models[0].efforts.map(\.id), ["high", "unknown"])
        XCTAssertEqual(models[0].efforts.map(\.totals.total), [30, 30])
    }

    func testExtraHighAliasesShareOneEffortRow() {
        let models = ResponseUsagePresentation.models([
            record("one", "2026-09-25T10:00:00Z", model: "gpt-6-sol", effort: "xhigh"),
            record("two", "2026-09-25T11:00:00Z", model: "gpt-6-sol", effort: "extra high")
        ])
        let extraHigh = models[0].efforts.filter { $0.id == "xhigh" }
        XCTAssertEqual(extraHigh.count, 1)
        XCTAssertEqual(extraHigh[0].label, "Extra high")
        XCTAssertEqual(extraHigh[0].totals.total, 60)
    }

    func testKnownModelKeepsUnknownEffortAndUnavailableValues() {
        let missing = ResponseTokenUsageRecord(timestamp: "2026-09-25T10:00:00Z", responseId: "missing",
            turnId: nil, sessionId: "s", threadId: "t", model: "gpt-6-sol", effort: "future-effort",
            usage: ResponseTokenUsage(inputTokens: nil, cachedInputTokens: 15,
                cacheWriteInputTokens: 2, outputTokens: nil, reasoningOutputTokens: 7, totalTokens: nil))
        let model = ResponseUsagePresentation.models([missing])[0]
        XCTAssertEqual(model.efforts.last?.label, "Unknown")
        XCTAssertNil(model.efforts.last?.totals.input)
        XCTAssertNil(model.efforts.last?.totals.total)
        XCTAssertEqual(model.efforts.first?.totals.total, 0)
    }

    func testSessionsContainThreadsAndNewestFirstResponsesWithNameFallback() {
        let records = [
            record("old", "2026-09-25T09:00:00Z", session: "s1", thread: "t1"),
            record("new", "2026-09-25T11:00:00Z", session: "s1", thread: "t1"),
            record("middle", "2026-09-25T10:00:00Z", session: "s1", thread: "t2"),
            record("other", "2026-09-25T08:00:00Z", session: "s2", thread: "t3")
        ]
        let sessions = ResponseUsagePresentation.sessions(records, names: ["s1": "Named work"])
        XCTAssertEqual(sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(sessions.map(\.displayName), ["Named work", "s2"])
        XCTAssertEqual(sessions[0].threads.map(\.id), ["t1", "t2"])
        XCTAssertEqual(sessions[0].threads[0].records.map(\.responseId), ["new", "old"])
        XCTAssertEqual(sessions[0].totals.total, 90)
    }

    func testSessionIndexParsesOnlyRequiredFieldsAndSkipsInvalidLines() throws {
        let data = Data("""
        {"id":"s1","thread_name":"Named work","conversation":"secret"}
        not-json
        {"id":"s2","thread_name":"  "}
        {"id":"s3","thread_name":"Another"}

        """.utf8)
        let names = SessionIndexNames.parse(data)
        XCTAssertEqual(names, ["s1": "Named work", "s3": "Another"])
        let emptyHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(SessionIndexNames.read(codexHomeURL: emptyHome), [:])
    }

    private func record(
        _ id: String, _ timestamp: String, model: String = "gpt-6-luna", effort: String = "medium",
        session: String = "s1", thread: String = "t1", total: Int64 = 30
    ) -> ResponseTokenUsageRecord {
        ResponseTokenUsageRecord(timestamp: timestamp, responseId: id, turnId: nil,
            sessionId: session, threadId: thread, model: model, effort: effort,
            usage: ResponseTokenUsage(inputTokens: 20, cachedInputTokens: 15,
                cacheWriteInputTokens: 2, outputTokens: 10, reasoningOutputTokens: 7, totalTokens: total))
    }
}
