import Foundation

public struct AppPriorityApplication: Codable, Equatable, Hashable {
    public let displayName: String
    public let bundleIdentifier: String
    public let bundlePath: String
    public let executablePath: String

    public init(displayName: String, bundleIdentifier: String, bundlePath: String, executablePath: String) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
    }
}

public struct AppPrioritySelection: Codable, Equatable {
    public let version: Int
    public let enabled: Bool
    public let application: AppPriorityApplication?

    public init(enabled: Bool, application: AppPriorityApplication?) {
        self.version = 1
        self.enabled = enabled
        self.application = application
    }

    public init(version: Int, enabled: Bool, application: AppPriorityApplication?) {
        self.version = version
        self.enabled = enabled
        self.application = application
    }
}

public struct AppPriorityStatus: Codable, Equatable {
    public enum State: String, Codable {
        case disabled
        case ready
        case waitingForSelectedApp
        case starting
        case active
        case activeWithSkipped
        case restorePending
        case restored
        case failed
    }

    public let state: State
    public let boostedCount: Int
    public let skippedCount: Int
    public let message: String
    public let sessionIdentifier: String?

    public init(state: State, boostedCount: Int, skippedCount: Int, message: String, sessionIdentifier: String?) {
        self.state = state
        self.boostedCount = boostedCount
        self.skippedCount = skippedCount
        self.message = message
        self.sessionIdentifier = sessionIdentifier
    }
}

public enum AppPriorityApplicationFilter {
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.windowserver",
        "com.apple.loginwindow",
        "local.catalinaperformance",
        "com.catalinaperformance",
        "local.catalinaperformance.priorityagent"
    ]

    private static let excludedDisplayNames: Set<String> = [
        "finder",
        "dock",
        "systemuiserver",
        "windowserver",
        "loginwindow",
        "catalinaperformance",
        "catalinaperformancepriorityagent"
    ]

    public static func isExcluded(bundleIdentifier: String, displayName: String) -> Bool {
        let normalizedIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedIdentifier.isEmpty { return true }
        if excludedBundleIdentifiers.contains(normalizedIdentifier) { return true }
        return excludedDisplayNames.contains(normalizedName)
    }
}

public enum AppPriorityConfigurationConflict: Equatable {
    case conflict(bundleIdentifier: String)

    public static func conflictingBundleIdentifier(
        selection: AppPriorityApplication?,
        foregroundBundleIdentifiers: Set<String>
    ) -> String? {
        guard let application = selection else { return nil }
        return foregroundBundleIdentifiers.contains(application.bundleIdentifier)
            ? application.bundleIdentifier
            : nil
    }

    public static func validate(
        priorityEnabled: Bool,
        priorityBundleIdentifier: String?,
        foregroundBundleIdentifiers: Set<String>
    ) -> AppPriorityConfigurationConflict? {
        guard priorityEnabled, let identifier = priorityBundleIdentifier else { return nil }
        return foregroundBundleIdentifiers.contains(identifier) ? .conflict(bundleIdentifier: identifier) : nil
    }

    public static func validateForegroundAddition(
        bundleIdentifier: String,
        priorityEnabled: Bool,
        priorityBundleIdentifier: String?
    ) -> AppPriorityConfigurationConflict? {
        guard priorityEnabled, priorityBundleIdentifier == bundleIdentifier else { return nil }
        return .conflict(bundleIdentifier: bundleIdentifier)
    }
}
