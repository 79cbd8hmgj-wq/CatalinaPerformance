import XCTest
import CatalinaPerformancePriorityCore
import CatalinaPerformanceMemoryCore
@testable import CatalinaPerformanceDashboardCore

final class MemorySessionMetricIntegrationTests: XCTestCase {
    func testCollectorCapturesMemoryTelemetryOnSameSessionSample() {
        let date = Date(timeIntervalSince1970: 1_000)
        let telemetry = MemoryTelemetrySnapshot(
            capturedAt: date,
            counters: MemoryVMCounters(
                physicalBytes: 4_294_967_296,
                availableBytes: 1_073_741_824,
                compressedBytes: 536_870_912,
                swapUsedBytes: 134_217_728,
                compressions: 10,
                decompressions: 5,
                pageIns: 2,
                pageOuts: 1,
                swapIns: 1,
                swapOuts: 1,
                pageSizeBytes: 4096
            ),
            rates: .unavailable,
            note: nil
        )
        let telemetryCollector = IntegrationTelemetryCollector(snapshot: telemetry)
        let coordinator = IntegrationMemoryCoordinator()
        let collector = SessionMetricsCollector(
            nativeMetrics: IntegrationNativeMetrics(),
            thermalProvider: IntegrationThermalProvider(),
            diskSpaceProvider: IntegrationDiskProvider(),
            selectionProvider: IntegrationSelectionProvider(),
            statusProvider: IntegrationStatusProvider(),
            currentUserProvider: IntegrationUserProvider(),
            processInspector: IntegrationProcessInspector(),
            memoryTelemetryCollector: telemetryCollector,
            memoryManagementCoordinator: coordinator
        )

        let snapshot = collector.capture(at: date, refreshThermal: true)

        XCTAssertEqual(telemetryCollector.capturedDates, [date])
        XCTAssertEqual(coordinator.evaluatedTelemetry, [telemetry])
        XCTAssertEqual(snapshot.memoryManagement?.capturedAt, date)
        XCTAssertEqual(snapshot.memoryManagement?.telemetry, telemetry)
    }

    func testSessionMetricSnapshotDecodesWhenOlderJSONHasNoMemoryManagementField() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let snapshot = SessionMetricSnapshot.unavailable(capturedAt: date, note: "fixture")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "memoryManagement")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(SessionMetricSnapshot.self, from: oldData)

        XCTAssertNil(decoded.memoryManagement)
        XCTAssertEqual(decoded.capturedAt, date)
    }
}

private final class IntegrationTelemetryCollector: MemoryTelemetryCollecting {
    let snapshot: MemoryTelemetrySnapshot
    var capturedDates: [Date] = []

    init(snapshot: MemoryTelemetrySnapshot) {
        self.snapshot = snapshot
    }

    func capture(at date: Date) -> MemoryTelemetrySnapshot {
        capturedDates.append(date)
        return snapshot
    }
}

private final class IntegrationMemoryCoordinator: MemoryManagementCoordinating {
    var evaluatedTelemetry: [MemoryTelemetrySnapshot] = []

    func prepareSession(identifier: String, at date: Date) throws -> MemoryManagementStatusSnapshot {
        return status(at: date, telemetry: nil)
    }

    func updateFrontmostApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot {
        return status(at: date, telemetry: nil)
    }

    func updateAppPriorityApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot {
        return status(at: date, telemetry: nil)
    }

    func evaluate(telemetry: MemoryTelemetrySnapshot) -> MemoryManagementStatusSnapshot {
        evaluatedTelemetry.append(telemetry)
        return status(at: telemetry.capturedAt, telemetry: telemetry)
    }

    func requestImmediateRestore(at date: Date) -> MemoryManagementStatusSnapshot {
        return status(at: date, telemetry: nil)
    }

    func currentStatus(at date: Date) -> MemoryManagementStatusSnapshot {
        return status(at: date, telemetry: nil)
    }

    private func status(at date: Date, telemetry: MemoryTelemetrySnapshot?) -> MemoryManagementStatusSnapshot {
        return MemoryManagementStatusSnapshot(
            capturedAt: date,
            pressureState: .healthy,
            managedFamilyCount: 0,
            managedFamilyNames: [],
            interventionActive: false,
            ioPolicyStatus: .unsupported,
            telemetry: telemetry,
            note: nil
        )
    }
}

private struct IntegrationNativeMetrics: DashboardNativeMetricsProviding {
    func hostCPUTicks() throws -> HostCPUTicks {
        throw DashboardNativeMetricError.unsupported
    }

    func hostMemory() throws -> HostMemorySample {
        return HostMemorySample(
            physicalTotalBytes: 4_294_967_296,
            usedBytes: 2_147_483_648,
            availableBytes: 2_147_483_648
        )
    }

    func swap() throws -> SwapSample {
        return SwapSample(totalBytes: 1_073_741_824, usedBytes: 134_217_728, freeBytes: 939_524_096)
    }

    func processResources(pid: Int32) throws -> ProcessResourceSample {
        throw DashboardNativeMetricError.unsupported
    }
}

private struct IntegrationThermalProvider: ThermalLimitProviding {
    func readLimits(capturedAt: Date) -> ThermalLimitSnapshot {
        return ThermalLimitSnapshot(
            capturedAt: capturedAt,
            schedulerLimitPercent: .available(100, at: capturedAt),
            speedLimitPercent: .available(100, at: capturedAt)
        )
    }
}

private struct IntegrationDiskProvider: DashboardDiskSpaceProviding {
    func startupVolumeFreeBytes() throws -> UInt64 { return 10_000 }
}

private struct IntegrationSelectionProvider: AppPrioritySelectionProviding {
    func currentSelection() -> AppPrioritySelection {
        return AppPrioritySelection(enabled: false, application: nil)
    }
}

private struct IntegrationStatusProvider: AppPriorityStatusProviding {
    func currentStatus() -> AppPriorityStatus? { return nil }
}

private struct IntegrationUserProvider: DashboardCurrentUserProviding {
    var uid: UInt32 { return 501 }
}

private final class IntegrationProcessInspector: AppPriorityProcessInspecting {
    func allProcesses() throws -> [AppPriorityProcessIdentity] { return [] }
    func process(pid: Int32) throws -> AppPriorityProcessIdentity {
        throw AppPriorityProcessError.unsupported
    }
}
