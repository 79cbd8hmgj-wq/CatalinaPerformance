import Foundation
import CatalinaPerformancePriorityCore
import CatalinaPerformanceMemoryCore

public protocol MemoryFrontmostApplicationObserving: AnyObject {}

#if canImport(AppKit)
import AppKit

public final class MemoryFrontmostApplicationObserver: MemoryFrontmostApplicationObserving {
    private weak var coordinator: MemoryManagementCoordinating?
    private var observer: NSObjectProtocol?

    public init(coordinator: MemoryManagementCoordinating) {
        self.coordinator = coordinator
        publishFrontmostApplication(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.publishFrontmostApplication(application)
        }
    }

    deinit {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func publishFrontmostApplication(_ runningApplication: NSRunningApplication?) {
        guard let coordinator = coordinator else { return }
        let application = runningApplication.flatMap(Self.priorityApplication)
        _ = coordinator.updateFrontmostApplication(application, at: Date())
    }

    private static func priorityApplication(_ runningApplication: NSRunningApplication) -> AppPriorityApplication? {
        guard let bundleIdentifier = runningApplication.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              let bundleURL = runningApplication.bundleURL,
              let executableURL = runningApplication.executableURL else {
            return nil
        }
        let displayName = runningApplication.localizedName ?? bundleURL.deletingPathExtension().lastPathComponent
        return AppPriorityApplication(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundleURL.standardizedFileURL.path,
            executablePath: executableURL.standardizedFileURL.path
        )
    }
}
#else

public final class MemoryFrontmostApplicationObserver: MemoryFrontmostApplicationObserving {
    public init(coordinator: MemoryManagementCoordinating) {}
}
#endif
