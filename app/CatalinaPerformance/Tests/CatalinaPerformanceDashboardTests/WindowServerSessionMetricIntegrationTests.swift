import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceDashboardCore

final class WindowServerSessionMetricIntegrationTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func testOldSnapshotWithoutWindowServerFieldDecodesWithNil() throws {
        let snapshot = SessionMetricSnapshot.unavailable(capturedAt: date(10), note: "legacy")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as! [String: Any]
        object.removeValue(forKey: "windowServerCPU")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(SessionMetricSnapshot.self, from: data)

        XCTAssertNil(decoded.windowServerCPU)
    }

    func testOldVersionOneRecordWithoutWindowServerFieldDecodesWithNil() throws {
        let snapshot = SessionMetricSnapshot.unavailable(capturedAt: date(10), note: "legacy")
        let record = PerformanceSessionRecord(
            sessionIdentifier: "legacy-session",
            phase: .active,
            startedAt: date(10),
            completedAt: nil,
            selectedApplication: nil,
            baseline: snapshot,
            latest: snapshot,
            finalPreRestore: nil,
            postRestore: nil,
            aggregates: SessionMetricAggregates(),
            sampleCount: 0,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(record)) as! [String: Any]
        object.removeValue(forKey: "windowServer")
        object["baseline"] = removeWindowServerCPU(from: object["baseline"])
        object["latest"] = removeWindowServerCPU(from: object["latest"])
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(PerformanceSessionRecord.self, from: data)

        XCTAssertNil(decoded.windowServer)
        XCTAssertNil(decoded.baseline.windowServerCPU)
        XCTAssertNil(decoded.latest.windowServerCPU)
    }

    func testOldCompletedReportWithoutWindowServerFieldDecodesWithNil() throws {
        let snapshot = SessionMetricSnapshot.unavailable(capturedAt: date(10), note: "legacy")
        let report = CompletedPerformanceSessionReport(
            sessionIdentifier: "legacy-report",
            phase: .completed,
            startedAt: date(10),
            completedAt: date(20),
            selectedApplication: nil,
            baseline: snapshot,
            finalPreRestore: nil,
            postRestore: nil,
            aggregates: SessionMetricAggregates(),
            sampleCount: 0,
            subsystemStatuses: [],
            monitoringGaps: [],
            metricErrors: [],
            completionReason: .normalOff
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(report)) as! [String: Any]
        object.removeValue(forKey: "windowServer")
        object["baseline"] = removeWindowServerCPU(from: object["baseline"])
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CompletedPerformanceSessionReport.self, from: data)

        XCTAssertNil(decoded.windowServer)
        XCTAssertNil(decoded.baseline.windowServerCPU)
    }

    func testSessionMetricsCollectorCarriesInjectedWindowServerReading() {
        let capturedAt = date(10)
        let expected = WindowServerCPUReading.available(
            processKey: WindowServerProcessKey(
                pid: 88,
                effectiveUID: 88,
                executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                startSeconds: 1,
                startMicroseconds: 0
            ),
            cumulativeCPUTimeNanoseconds: 2_000_000_000,
            cpuPercent: 12.5,
            at: capturedAt
        )
        let collector = makeCollector(windowServer: WSStubWindowServerCollector(reading: expected))

        let snapshot = collector.capture(at: capturedAt, refreshThermal: true)

        XCTAssertEqual(snapshot.windowServerCPU, expected)
    }

    func testSessionMetricsCollectorWithoutWindowServerCollectorLeavesMetricNil() {
        let snapshot = makeCollector(windowServer: nil).capture(at: date(10), refreshThermal: true)
        XCTAssertNil(snapshot.windowServerCPU)
    }

    private func removeWindowServerCPU(from value: Any?) -> Any? {
        guard var object = value as? [String: Any] else { return value }
        object.removeValue(forKey: "windowServerCPU")
        return object
    }

    private func makeCollector(windowServer: WindowServerMetricsCollecting?) -> SessionMetricsCollector {
        SessionMetricsCollector(
            nativeMetrics: WSStubNativeMetrics(),
            thermalProvider: WSStubThermalProvider(),
            diskSpaceProvider: WSStubDiskProvider(),
            selectionProvider: WSStubSelectionProvider(),
            statusProvider: WSStubStatusProvider(),
            currentUserProvider: WSStubUserProvider(),
            processInspector: WSStubProcessInspector(),
            windowServerCollector: windowServer
        )
    }
}

private final class WSStubWindowServerCollector: WindowServerMetricsCollecting {
    let reading: WindowServerCPUReading
    init(reading: WindowServerCPUReading) { self.reading = reading }
    func capture(at date: Date) -> WindowServerCPUReading { reading }
    func reset() {}
}

private struct WSStubNativeMetrics: DashboardNativeMetricsProviding {
    func hostCPUTicks() throws -> HostCPUTicks {
        throw DashboardNativeMetricError.unsupported
    }
    func hostMemory() throws -> HostMemorySample {
        HostMemorySample(physicalTotalBytes: 8_000, usedBytes: 4_000, availableBytes: 4_000)
    }
    func swap() throws -> SwapSample {
        SwapSample(totalBytes: 1_000, usedBytes: 100, freeBytes: 900)
    }
    func processResources(pid: Int32) throws -> ProcessResourceSample {
        throw DashboardNativeMetricError.unsupported
    }
}

private final class WSStubThermalProvider: ThermalLimitProviding {
    func readLimits(capturedAt: Date) -> ThermalLimitSnapshot {
        ThermalLimitSnapshot(
            capturedAt: capturedAt,
            schedulerLimitPercent: .available(100, at: capturedAt),
            speedLimitPercent: .available(100, at: capturedAt)
        )
    }
}

private struct WSStubDiskProvider: DashboardDiskSpaceProviding {
    func startupVolumeFreeBytes() throws -> UInt64 { 10_000 }
}

private struct WSStubSelectionProvider: AppPrioritySelectionProviding {
    func currentSelection() -> AppPrioritySelection {
        AppPrioritySelection(enabled: false, application: nil)
    }
}

private struct WSStubStatusProvider: AppPriorityStatusProviding {
    func currentStatus() -> AppPriorityStatus? { nil }
}

private struct WSStubUserProvider: DashboardCurrentUserProviding {
    let uid: UInt32 = 501
}

private final class WSStubProcessInspector: AppPriorityProcessInspecting {
    func allProcesses() throws -> [AppPriorityProcessIdentity] { [] }
    func process(pid: Int32) throws -> AppPriorityProcessIdentity {
        throw AppPriorityProcessError.unsupported
    }
}
