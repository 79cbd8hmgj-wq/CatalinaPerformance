import Foundation
import CatalinaPerformancePriorityCore

public extension SessionMetricsCollector {
    convenience init(
        nativeMetrics: DarwinDashboardNativeMetrics,
        thermalProvider: ThermalLimitProviding,
        diskSpaceProvider: DashboardDiskSpaceProviding,
        selectionProvider: AppPrioritySelectionProviding,
        statusProvider: AppPriorityStatusProviding,
        currentUserProvider: DashboardCurrentUserProviding,
        processInspector: DarwinAppPriorityProcessInspector
    ) {
        let windowServerCollector = WindowServerMetricsCollector(
            processInspector: processInspector,
            nativeMetrics: nativeMetrics
        )
        self.init(
            nativeMetrics: nativeMetrics,
            thermalProvider: thermalProvider,
            diskSpaceProvider: diskSpaceProvider,
            selectionProvider: selectionProvider,
            statusProvider: statusProvider,
            currentUserProvider: currentUserProvider,
            processInspector: processInspector,
            windowServerCollector: windowServerCollector
        )
    }
}
