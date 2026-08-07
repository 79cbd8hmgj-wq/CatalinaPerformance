import Foundation
import CatalinaPerformancePriorityCore
import CatalinaPerformanceMemoryCore

#if canImport(AppKit)
import AppKit
#endif

/// Production-only handoff used to ensure the SessionMetricsCollector and
/// PerformanceSessionCoordinator share one Memory Management coordinator.
/// Tests that construct either type directly remain isolated and receive no
/// production coordinator unless they explicitly provide one.
public enum ProductionMemoryManagementIntegration {
    private static let lock = NSLock()
    private static var coordinatorValue: MemoryManagementCoordinating?
#if canImport(AppKit)
    private static var foregroundObserver: ProductionMemoryForegroundObserver?
#endif

    public static func makeAndInstall(
        requestingUID: UInt32,
        processInspector: DarwinAppPriorityProcessInspector
    ) -> MemoryManagementCoordinating? {
        guard requestingUID > 0 else { return nil }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CatalinaPerformance", isDirectory: true)
            .appendingPathComponent("memory_management", isDirectory: true)
        let coordinator = MemoryManagementCoordinator(
            desiredStateStore: MemoryDesiredStateStore(directoryURL: directory),
            processInspector: processInspector,
            resourceInspector: processInspector,
            requestingUID: requestingUID
        )
        install(coordinator)
        return coordinator
    }

    public static func install(_ coordinator: MemoryManagementCoordinating) {
        lock.lock()
        coordinatorValue = coordinator
#if canImport(AppKit)
        foregroundObserver?.stop()
        let observer = ProductionMemoryForegroundObserver(coordinator: coordinator)
        foregroundObserver = observer
#endif
        lock.unlock()
#if canImport(AppKit)
        observer.start()
#endif
    }

    public static func currentCoordinator() -> MemoryManagementCoordinating? {
        lock.lock()
        let value = coordinatorValue
        lock.unlock()
        return value
    }
}

public extension PerformanceSessionCoordinator {
    /// Exact production overload used by the GUI. It selects the coordinator
    /// installed by ProductionSessionMetricsCollector without changing the
    /// designated initializer's nil default used by isolated tests.
    convenience init(
        collector: SessionMetricsCollecting,
        recorder: PerformanceSessionRecording,
        store: PerformanceSessionStoring,
        evidenceProvider: PerformanceSubsystemEvidenceProviding,
        modeStateProvider: PerformanceModeStateProviding,
        callbackQueue: DispatchQueue
    ) {
        self.init(
            collector: collector,
            recorder: recorder,
            store: store,
            evidenceProvider: evidenceProvider,
            modeStateProvider: modeStateProvider,
            callbackQueue: callbackQueue,
            memoryManagementCoordinator: ProductionMemoryManagementIntegration.currentCoordinator()
        )
    }
}

#if canImport(AppKit)
private final class ProductionMemoryForegroundObserver {
    private weak var coordinator: MemoryManagementCoordinating?
    private var token: NSObjectProtocol?

    init(coordinator: MemoryManagementCoordinating) {
        self.coordinator = coordinator
    }

    func start() {
        precondition(Thread.isMainThread)
        update(NSWorkspace.shared.frontmostApplication)
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.update(application)
        }
    }

    func stop() {
        guard let token = token else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(token)
        self.token = nil
    }

    private func update(_ running: NSRunningApplication?) {
        precondition(Thread.isMainThread)
        let identity: AppPriorityApplication?
        if let running = running,
           let displayName = running.localizedName,
           !displayName.isEmpty,
           let bundleIdentifier = running.bundleIdentifier,
           !bundleIdentifier.isEmpty,
           let bundlePath = running.bundleURL?.standardizedFileURL.path,
           !bundlePath.isEmpty,
           let executablePath = running.executableURL?.standardizedFileURL.path,
           !executablePath.isEmpty {
            identity = AppPriorityApplication(
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                bundlePath: bundlePath,
                executablePath: executablePath
            )
        } else {
            identity = nil
        }
        _ = coordinator?.updateFrontmostApplication(identity, at: Date())
    }
}
#endif
