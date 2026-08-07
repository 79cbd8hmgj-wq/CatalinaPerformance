import XCTest
@testable import CatalinaPerformanceDashboardCore

final class WindowServerPerformanceSessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCompletedReportWithGraphicsMetricsRoundTripsExactly() throws {
        let store = PerformanceSessionStore(directoryURL: root)
        let expected = report(identifier: "graphics", graphics: populatedGraphics())

        try store.saveCompleted(expected)
        guard case .loaded(let loaded) = store.loadCompleted() else {
            return XCTFail("Expected completed graphics report")
        }

        XCTAssertEqual(loaded, expected)
        let data = try Data(
            contentsOf: root.appendingPathComponent("last-completed-session.json")
        )
        XCTAssertLessThan(data.count, 1_048_576)
    }

    func testLegacySchemaOneCompletedReportWithoutGraphicsLoadsNormally() throws {
        let store = PerformanceSessionStore(directoryURL: root)
        let legacy = report(identifier: "legacy", graphics: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(legacy)
        let url = root.appendingPathComponent("last-completed-session.json")
        try data.write(to: url, options: .atomic)

        guard case .loaded(let loaded) = store.loadCompleted() else {
            return XCTFail("Expected legacy report to load instead of being quarantined")
        }

        XCTAssertEqual(loaded.sessionIdentifier, "legacy")
        XCTAssertNil(loaded.windowServer)
        XCTAssertNil(loaded.baseline.windowServerCPU)
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: root.path))
                .contains(where: { $0.hasPrefix("last-completed-session.invalid-") })
        )
    }

    func testInterruptedGraphicsReportPersistsFinalPreRestoreReading() throws {
        let store = PerformanceSessionStore(directoryURL: root)
        var graphics = populatedGraphics()
        graphics.finalPreRestoreCPU = 27.5
        graphics.postRestoreCPU = nil
        let interrupted = CompletedPerformanceSessionReport(
            sessionIdentifier: "interrupted",
            phase: .interrupted,
            startedAt: date(0),
            completedAt: date(20),
            selectedApplication: nil,
            baseline: snapshot(at: 0),
            finalPreRestore: snapshot(at: 18),
            postRestore: nil,
            aggregates: SessionMetricAggregates(),
            sampleCount: 5,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: .interrupted,
            windowServer: graphics
        )

        try store.saveCompleted(interrupted)
        guard case .loaded(let loaded) = store.loadCompleted() else {
            return XCTFail("Expected interrupted report")
        }

        XCTAssertEqual(loaded.phase, .interrupted)
        XCTAssertEqual(loaded.windowServer?.finalPreRestoreCPU, 27.5)
        XCTAssertNil(loaded.windowServer?.postRestoreCPU)
        XCTAssertEqual(loaded.windowServer?.baselineSamples.count, 3)
    }

    private func populatedGraphics() -> WindowServerSessionAggregate {
        var graphics = WindowServerSessionAggregate()
        graphics.beginBaseline()
        graphics.recordBaseline(reading(cpu: nil, at: 0))
        graphics.recordBaseline(reading(cpu: 8, at: 2))
        graphics.recordBaseline(reading(cpu: 12, at: 4))
        graphics.finalizeBaseline()
        graphics.recordActive(reading(cpu: 16, at: 6), at: date(6))
        graphics.recordActive(reading(cpu: 22, at: 8), at: date(8))
        graphics.recordActive(reading(cpu: 31, at: 10), at: date(10))
        graphics.recordActive(reading(cpu: 33, at: 12), at: date(12))
        graphics.finalPreRestoreCPU = 20
        graphics.postRestoreCPU = 11
        return graphics
    }

    private func report(
        identifier: String,
        graphics: WindowServerSessionAggregate?
    ) -> CompletedPerformanceSessionReport {
        let baseline = snapshot(at: 0)
        return CompletedPerformanceSessionReport(
            sessionIdentifier: identifier,
            phase: .completed,
            startedAt: date(0),
            completedAt: date(20),
            selectedApplication: nil,
            baseline: baseline,
            finalPreRestore: snapshot(at: 18),
            postRestore: snapshot(at: 20),
            aggregates: SessionMetricAggregates(),
            sampleCount: 5,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: .normalOff,
            windowServer: graphics
        )
    }

    private func snapshot(at seconds: TimeInterval) -> SessionMetricSnapshot {
        SessionMetricSnapshot.unavailable(
            capturedAt: date(seconds),
            note: "fixture"
        )
    }

    private func reading(
        cpu: Double?,
        at seconds: TimeInterval
    ) -> WindowServerCPUReading {
        let capturedAt = date(seconds)
        let key = WindowServerProcessKey(
            pid: 88,
            effectiveUID: 88,
            executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            startSeconds: 1,
            startMicroseconds: 0
        )
        guard let cpu = cpu else {
            return .unavailable(
                processKey: key,
                at: capturedAt,
                note: "counter baseline"
            )
        }
        return .available(
            processKey: key,
            cumulativeCPUTimeNanoseconds: UInt64(cpu * 1_000_000),
            cpuPercent: cpu,
            at: capturedAt
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
