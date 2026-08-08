import Foundation
import CatalinaPerformancePriorityCore
import CatalinaPerformanceMemoryCore

public extension SessionMetricsCollector {
    convenience init(
        nativeMetrics: DarwinDashboardNativeMetrics,
        thermalProvider: ThermalLimitProviding,
        diskSpaceProvider: DashboardDiskSpaceProviding,
        selectionProvider: AppPrioritySelectionProviding,
        statusProvider: AppPriorityStatusProviding,
        currentUserProvider: DashboardCurrentUserProviding,
        processInspector: DarwinAppPriorityProcessInspector,
        memoryManagementCoordinator: MemoryManagementCoordinating? = nil
    ) {
        let windowServerCollector = WindowServerMetricsCollector(
            processInspector: DarwinWindowServerProcessInspector()
        )
        let memoryCoordinator = memoryManagementCoordinator ?? MemoryManagementCoordinator()

        self.init(
            nativeMetrics: nativeMetrics,
            thermalProvider: thermalProvider,
            diskSpaceProvider: diskSpaceProvider,
            selectionProvider: selectionProvider,
            statusProvider: statusProvider,
            currentUserProvider: currentUserProvider,
            processInspector: processInspector,
            windowServerCollector: windowServerCollector,
            memoryTelemetryCollector: DarwinMemoryTelemetryCollector(),
            memoryManagementCoordinator: memoryCoordinator,
            memoryFrontmostObserver: nil
        )
    }
}
