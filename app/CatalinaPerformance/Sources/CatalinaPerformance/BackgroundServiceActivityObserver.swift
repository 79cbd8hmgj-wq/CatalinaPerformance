#if canImport(AppKit)
import AppKit
import CatalinaPerformanceBackgroundServicesCore

protocol BackgroundServiceActivityObserving: AnyObject {
    func start()
    func stop()
}

final class BackgroundServiceActivityObserver: BackgroundServiceActivityObserving {
    private let coordinator: BackgroundServiceSuppressionCoordinating
    private let workspace: NSWorkspace
    private let catalog: CatalinaBackgroundServiceCatalog
    private var observerTokens: [NSObjectProtocol] = []
    private var resumedCategories: Set<BackgroundServiceCategory> = []

    init(
        coordinator: BackgroundServiceSuppressionCoordinating,
        workspace: NSWorkspace = .shared,
        catalog: CatalinaBackgroundServiceCatalog = .current
    ) {
        self.coordinator = coordinator
        self.workspace = workspace
        self.catalog = catalog
    }

    func start() {
        guard observerTokens.isEmpty else { return }
        resumedCategories.removeAll()
        let center = workspace.notificationCenter
        observerTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main,
            using: { [weak self] notification in self?.handle(notification) }
        ))
        observerTokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
            using: { [weak self] notification in self?.handle(notification) }
        ))
    }

    func stop() {
        let center = workspace.notificationCenter
        observerTokens.forEach { center.removeObserver($0) }
        observerTokens.removeAll()
        resumedCategories.removeAll()
    }

    deinit {
        stop()
    }

    private func handle(_ notification: Notification) {
        guard let runningApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleIdentifier = runningApplication.bundleIdentifier,
              let category = catalog.category(forAssociatedBundleIdentifier: bundleIdentifier),
              !resumedCategories.contains(category) else {
            return
        }
        resumedCategories.insert(category)
        coordinator.resume(category: category, reason: resumeReason(category: category, applicationName: runningApplication.localizedName), completion: nil)
    }

    private func resumeReason(category: BackgroundServiceCategory, applicationName: String?) -> String {
        let name = applicationName ?? fallbackName(for: category)
        return "User opened \(name)."
    }

    private func fallbackName(for category: BackgroundServiceCategory) -> String {
        switch category {
        case .softwareUpdate: return "System Preferences"
        case .appStoreUpdates: return "App Store"
        case .photos: return "Photos"
        case .mail: return "Mail"
        case .messagesFaceTime: return "Messages or FaceTime"
        case .siriSpeech: return "Siri"
        case .iCloudDrive: return "iCloud Drive"
        }
    }
}
#endif
