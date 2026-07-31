import XCTest
@testable import CatalinaPerformanceDashboardCore

final class PerformanceSessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCompletedReportReplacesPreviousReport() throws {
        let store = PerformanceSessionStore(directoryURL: root)
        try store.saveCompleted(report(identifier: "first"))
        try store.saveCompleted(report(identifier: "second"))
        guard case .loaded(let loaded) = store.loadCompleted() else { return XCTFail("Expected completed report") }
        XCTAssertEqual(loaded.sessionIdentifier, "second")
    }

    func testActiveWriteUses0600AndRemoveDoesNotDeleteCompleted() throws {
        let store = PerformanceSessionStore(directoryURL: root)
        let active = record(identifier: "active")
        try store.saveActive(active)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("active-session.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.saveCompleted(report(identifier: "completed"))
        try store.removeActive()
        if case .loaded(let loaded) = store.loadCompleted() { XCTAssertEqual(loaded.sessionIdentifier, "completed") } else { XCTFail("missing") }
    }

    func testOversizedAndMalformedFilesAreRecoveredAsInvalidBackups() throws {
        let store = PerformanceSessionStore(directoryURL: root)
        let activeURL = root.appendingPathComponent("active-session.json")
        try Data(repeating: 65, count: 1_048_577).write(to: activeURL)
        guard case .recoveredInvalid = store.loadActive() else { return XCTFail("Expected recovery") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeURL.path))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: root.path)).filter { $0.hasPrefix("active-session.invalid-") }.isEmpty)
    }

    func testSymlinkFileIsRefusedWithoutTouchingTarget() throws {
        let target = root.appendingPathComponent("target.json")
        try Data("original".utf8).write(to: target)
        let active = root.appendingPathComponent("active-session.json")
        try FileManager.default.createSymbolicLink(at: active, withDestinationURL: target)
        let store = PerformanceSessionStore(directoryURL: root)
        XCTAssertThrowsError(try store.saveActive(record(identifier: "new")))
        XCTAssertEqual(String(data: try Data(contentsOf: target), encoding: .utf8), "original")
    }

    private func record(identifier: String) -> PerformanceSessionRecord {
        let d = Date(timeIntervalSince1970: 0)
        let snapshot = SessionMetricSnapshot.unavailable(capturedAt: d, note: "fixture")
        return PerformanceSessionRecord(sessionIdentifier: identifier, phase: .active, startedAt: d, completedAt: nil, selectedApplication: nil, baseline: snapshot, latest: snapshot, finalPreRestore: nil, postRestore: nil, aggregates: SessionMetricAggregates(), sampleCount: 0, subsystemStatuses: [], monitoringGaps: [], metricErrors: [], completionReason: nil)
    }

    private func report(identifier: String) -> CompletedPerformanceSessionReport {
        let d = Date(timeIntervalSince1970: 0)
        let snapshot = SessionMetricSnapshot.unavailable(capturedAt: d, note: "fixture")
        return CompletedPerformanceSessionReport(sessionIdentifier: identifier, phase: .completed, startedAt: d, completedAt: d, selectedApplication: nil, baseline: snapshot, finalPreRestore: nil, postRestore: nil, aggregates: SessionMetricAggregates(), sampleCount: 0, subsystemStatuses: [], monitoringGaps: [], metricErrors: [], completionReason: .normalOff)
    }
}
