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
        let resolvedMemoryCoordinator: MemoryManagementCoordinating
        if let memoryManagementCoordinator = memoryManagementCoordinator {
            resolvedMemoryCoordinator = memoryManagementCoordinator
        } else {
            let desiredStateDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("CatalinaPerformance", isDirectory: true)
                .appendingPathComponent("memory_management", isDirectory: true)
            resolvedMemoryCoordinator = MemoryManagementCoordinator(
                desiredStateStore: MemoryDesiredStateStore(directoryURL: desiredStateDirectory),
                processInspector: processInspector,
                resourceInspector: processInspector,
                requestingUID: currentUserProvider.uid
            )
        }
        let frontmostObserver = MemoryFrontmostApplicationObserver(
            coordinator: resolvedMemoryCoordinator
        )
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
            memoryManagementCoordinator: resolvedMemoryCoordinator,
            memoryFrontmostObserver: frontmostObserver
        )
    }
}
