import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceDashboardCore

final class WindowServerProductionWiringTests: XCTestCase {
    func testDarwinProductionInitializerInstallsWindowServerCollector() {
        let collector = SessionMetricsCollector(
            nativeMetrics: DarwinDashboardNativeMetrics(),
            thermalProvider: ProductionWiringThermalProvider(),
            diskSpaceProvider: ProductionWiringDiskProvider(),
            selectionProvider: ProductionWiringSelectionProvider(),
            statusProvider: ProductionWiringStatusProvider(),
            currentUserProvider: ProductionWiringUserProvider(),
            processInspector: DarwinAppPriorityProcessInspector()
        )

        let snapshot = collector.capture(
            at: Date(timeIntervalSince1970: 10),
            refreshThermal: true
        )

        XCTAssertNotNil(snapshot.windowServerCPU)
    }

    func testExplicitFakeWindowServerCollectorIsCalledExactlyOncePerCapture() {
        let windowServer = CountingWindowServerCollector()
        let collector = SessionMetricsCollector(
            nativeMetrics: ProductionWiringNativeMetrics(),
            thermalProvider: ProductionWiringThermalProvider(),
            diskSpaceProvider: ProductionWiringDiskProvider(),
            selectionProvider: ProductionWiringSelectionProvider(),
            statusProvider: ProductionWiringStatusProvider(),
            currentUserProvider: ProductionWiringUserProvider(),
            processInspector: ProductionWiringProcessInspector(),
            windowServerCollector: windowServer
        )

        _ = collector.capture(
            at: Date(timeIntervalSince1970: 10),
            refreshThermal: true
        )

        XCTAssertEqual(windowServer.captureCount, 1)
    }
}

private final class CountingWindowServerCollector: WindowServerMetricsCollecting {
    private(set) var captureCount = 0

    func capture(at date: Date) -> WindowServerCPUReading {
        captureCount += 1
        return .unavailable(
            processKey: nil,
            at: date,
            note: "fixture"
        )
    }

    func reset() {}
}

private struct ProductionWiringNativeMetrics: DashboardNativeMetricsProviding {
    func hostCPUTicks() throws -> HostCPUTicks {
        throw DashboardNativeMetricError.unsupported
    }

    func hostMemory() throws -> HostMemorySample {
        HostMemorySample(
            physicalTotalBytes: 8_000,
            usedBytes: 4_000,
            availableBytes: 4_000
        )
    }

    func swap() throws -> SwapSample {
        SwapSample(totalBytes: 1_000, usedBytes: 100, freeBytes: 900)
    }

    func processResources(pid: Int32) throws -> ProcessResourceSample {
        throw DashboardNativeMetricError.unsupported
    }
}

private final class ProductionWiringThermalProvider: ThermalLimitProviding {
    func readLimits(capturedAt: Date) -> ThermalLimitSnapshot {
        ThermalLimitSnapshot(
            capturedAt: capturedAt,
            schedulerLimitPercent: .available(100, at: capturedAt),
            speedLimitPercent: .available(100, at: capturedAt)
        )
    }
}

private struct ProductionWiringDiskProvider: DashboardDiskSpaceProviding {
    func startupVolumeFreeBytes() throws -> UInt64 { 10_000 }
}

private struct ProductionWiringSelectionProvider: AppPrioritySelectionProviding {
    func currentSelection() -> AppPrioritySelection {
        AppPrioritySelection(enabled: false, application: nil)
    }
}

private struct ProductionWiringStatusProvider: AppPriorityStatusProviding {
    func currentStatus() -> AppPriorityStatus? { nil }
}

private struct ProductionWiringUserProvider: DashboardCurrentUserProviding {
    let uid: UInt32 = 501
}

private final class ProductionWiringProcessInspector: AppPriorityProcessInspecting {
    func allProcesses() throws -> [AppPriorityProcessIdentity] { [] }

    func process(pid: Int32) throws -> AppPriorityProcessIdentity {
        throw AppPriorityProcessError.unsupported
    }
}
