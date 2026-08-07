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
            let baseCoordinator = MemoryManagementCoordinator(
                desiredStateStore: MemoryDesiredStateStore(directoryURL: desiredStateDirectory),
                processInspector: processInspector,
                resourceInspector: processInspector,
                requestingUID: currentUserProvider.uid
            )
            let agentStatusURL = URL(
                fileURLWithPath: "/var/run/CatalinaPerformance",
                isDirectory: true
            )
                .appendingPathComponent(String(currentUserProvider.uid), isDirectory: true)
                .appendingPathComponent("memory_management", isDirectory: true)
                .appendingPathComponent("status.json")
            resolvedMemoryCoordinator = AgentConfirmedMemoryManagementCoordinator(
                base: baseCoordinator,
                agentStatusProvider: FileMemoryAgentStatusProvider(statusURL: agentStatusURL)
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
