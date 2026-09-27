import Foundation
import XCTest
import CoreServices
@testable import CodexUsageCore

final class SessionLogChangeWatcherTests: XCTestCase {
    private final class ExpectedTotals: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int64: XCTestExpectation]

        init(_ pending: [Int64: XCTestExpectation]) { self.pending = pending }

        func record(_ total: Int64) {
            lock.lock()
            let expectation = pending.removeValue(forKey: total)
            lock.unlock()
            expectation?.fulfill()
        }
    }

    func testExistingSessionUpdatesForRepeatedAppendsWithoutClosingWriter() throws {
        try exerciseHeldOpenWriter(fileExistsAtStartup: true)
    }

    func testNewSessionUpdatesForRepeatedAppendsWithoutClosingWriter() throws {
        try exerciseHeldOpenWriter(fileExistsAtStartup: false)
    }

    func testReplacedSessionUpdatesForRepeatedAppendsWithoutClosingWriter() throws {
        try exerciseHeldOpenWriter(fileExistsAtStartup: true, replaceBeforeAppends: true)
    }

    func testStopCancelsPendingDeliveryAndAllowsDeallocation() throws {
        let sessions = FileManager.default.temporaryDirectory
            .appendingPathComponent("stopped-watcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessions) }
        let file = sessions.appendingPathComponent("open-writer.jsonl")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let unexpected = expectation(description: "no callbacks after stopping watcher")
        unexpected.isInverted = true
        var watcher: SessionLogChangeWatcher? = SessionLogChangeWatcher(rootURL: sessions, latency: 0.1) { _ in
            unexpected.fulfill()
        }
        weak var releasedWatcher = watcher
        XCTAssertTrue(watcher!.start())
        try handle.write(contentsOf: Data("before stop\n".utf8))
        watcher?.stop()
        watcher = nil
        XCTAssertNil(releasedWatcher)
        try handle.write(contentsOf: Data("after stop\n".utf8))
        wait(for: [unexpected], timeout: 0.5)
    }

    private func exerciseHeldOpenWriter(fileExistsAtStartup: Bool, replaceBeforeAppends: Bool = false) throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-open-session-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("open-writer.jsonl")
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        func line(_ tokens: Int64) -> Data {
            Data("{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(tokens)}}}}\n".utf8)
        }
        if fileExistsAtStartup { try line(10).write(to: file) }
        let counter = LocalTokenUsageCounter(codexHomeURL: codexHome)
        let initial = try counter.reconcileToday(now: now)
        XCTAssertEqual(initial, fileExistsAtStartup ? 10 : 0)
        let appends: [Int64] = [42, 7, 11]
        var total = initial
        let steps = appends.map { tokens -> (tokens: Int64, expectation: XCTestExpectation) in
            total += tokens
            return (tokens, expectation(description: "total reaches \(total) while writer remains open"))
        }
        total = initial
        var expectations: [Int64: XCTestExpectation] = [:]
        for step in steps {
            total += step.tokens
            expectations[total] = step.expectation
        }
        let progress = ExpectedTotals(expectations)
        let watcher = SessionLogChangeWatcher(rootURL: sessions, latency: 0.1) { batch in
            let result = Result {
                if batch.requiresReconciliation { return try counter.reconcileToday(now: now) }
                return try counter.processChangedFiles(batch.changedFiles, now: now)
            }
            if case .success(let value) = result { progress.record(value) }
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        if !fileExistsAtStartup { try Data().write(to: file) }
        if replaceBeforeAppends { try line(10).write(to: file, options: .atomic) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for step in steps {
            // Separate writes into different event batches while retaining the same writer descriptor.
            Thread.sleep(forTimeInterval: 0.3)
            let startedAt = Date()
            try handle.write(contentsOf: line(step.tokens))
            wait(for: [step.expectation], timeout: 2)
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        }
    }

    func testWatcherAndCounterUpdateWithinTwoSeconds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-watcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.deletingLastPathComponent()
            .appendingPathComponent("counter-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let counter = LocalTokenUsageCounter(codexHomeURL: codexHome)
        let now = Date()
        let file = sessions.appendingPathComponent("changed.jsonl")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let initialLine = "{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: now))\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":10}}}}\n"
        try Data(initialLine.utf8).write(to: file)
        XCTAssertEqual(try counter.reconcileToday(now: now), 10)

        let updated = expectation(description: "token total updated from changed session file")
        let changeStartedAt = Date()
        let watcher = SessionLogChangeWatcher(rootURL: sessions, latency: 0.1) { batch in
            guard batch.changedFiles.contains(file.standardizedFileURL) else { return }
            let result = Result {
                if batch.requiresReconciliation {
                    return try counter.reconcileToday(now: now)
                }
                return try counter.processChangedFiles(batch.changedFiles, now: now)
            }
            guard case .success(52) = result else { return }
            XCTAssertLessThan(Date().timeIntervalSince(changeStartedAt), 2)
            updated.fulfill()
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }

        let line = "{\"type\":\"event_msg\",\"timestamp\":\"\(formatter.string(from: now))\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":42}}}}\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
        wait(for: [updated], timeout: 3)
    }

    func testWatcherCannotStartWhenRootDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-session-watcher-\(UUID().uuidString)", isDirectory: true)
        let watcher = SessionLogChangeWatcher(rootURL: missing) { _ in }
        XCTAssertFalse(watcher.start())
    }

    func testDroppedAndStructuralEventsRequireReconciliation() {
        XCTAssertTrue(SessionLogChangeWatcher.requiresReconciliation(for: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)))
        XCTAssertTrue(SessionLogChangeWatcher.requiresReconciliation(for: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)))
        XCTAssertTrue(SessionLogChangeWatcher.requiresReconciliation(for: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)))
        XCTAssertTrue(SessionLogChangeWatcher.requiresReconciliation(for: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)))
        XCTAssertFalse(SessionLogChangeWatcher.requiresReconciliation(for: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)))
        XCTAssertTrue(SessionLogChangeWatcher.rootWasChanged(for: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)))
    }
}
