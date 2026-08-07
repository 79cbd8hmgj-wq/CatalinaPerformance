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

public enum AppPriorityTargetScope: String, Codable, Equatable {
    case mainProcessOnly
    case verifiedProcessFamily
}

public enum AppPriorityPolicyKind: String, Codable, Equatable {
    case verifiedProcessFamily
    case mainProcessOnly
    case focusedFirefox
}

public struct AppPriorityPolicy: Equatable {
    public let kind: AppPriorityPolicyKind
    public let targetNiceValue: Int32
    public let maximumBoostedCount: Int?

    public init(kind: AppPriorityPolicyKind, targetNiceValue: Int32, maximumBoostedCount: Int?) {
        self.kind = kind
        self.targetNiceValue = targetNiceValue
        self.maximumBoostedCount = maximumBoostedCount
    }

    public static func policy(for application: AppPriorityApplication) -> AppPriorityPolicy {
        let identifier = application.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if identifier == "org.mozilla.firefox" {
            return AppPriorityPolicy(kind: .focusedFirefox, targetNiceValue: -1, maximumBoostedCount: 3)
        }
        if isKnownBrowser(bundleIdentifier: identifier) {
            return AppPriorityPolicy(kind: .mainProcessOnly, targetNiceValue: -2, maximumBoostedCount: 1)
        }
        return AppPriorityPolicy(kind: .verifiedProcessFamily, targetNiceValue: -5, maximumBoostedCount: nil)
    }

    public static func isKnownBrowser(bundleIdentifier: String) -> Bool {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact: Set<String> = [
            "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly",
            "com.apple.safari",
            "com.apple.safaritechnologypreview",
            "com.google.chrome",
            "com.google.chrome.canary",
            "org.chromium.chromium",
            "com.microsoft.edgemac",
            "com.microsoft.edgemac.beta",
            "com.microsoft.edgemac.dev",
            "com.microsoft.edgemac.canary",
            "com.brave.browser",
            "com.operasoftware.opera",
            "com.vivaldi.vivaldi"
        ]
        return exact.contains(identifier)
    }

    public var legacyScope: AppPriorityTargetScope {
        switch kind {
        case .mainProcessOnly:
            return .mainProcessOnly
        case .verifiedProcessFamily, .focusedFirefox:
            return .verifiedProcessFamily
        }
    }

    public var summary: String {
        switch kind {
        case .focusedFirefox:
            return "Focused Firefox policy: parent, GPU, and one stable content process at nice \(targetNiceValue)"
        case .mainProcessOnly:
            return "Browser policy: main process only at nice \(targetNiceValue)"
        case .verifiedProcessFamily:
            return "Sustained-workload policy: verified process family at nice \(targetNiceValue)"
        }
    }
}

public struct FocusedFirefoxStatusDetails: Codable, Equatable {
    public let trackedProcessCount: Int
    public let actuallyBoostedCount: Int
    public let parentPID: Int32?
    public let gpuPID: Int32?
    public let contentPID: Int32?
    public let waitingForStableContent: Bool
    public let warning: String?

    public init(
        trackedProcessCount: Int,
        actuallyBoostedCount: Int,
        parentPID: Int32?,
        gpuPID: Int32?,
        contentPID: Int32?,
        waitingForStableContent: Bool,
        warning: String?
    ) {
        self.trackedProcessCount = trackedProcessCount
        self.actuallyBoostedCount = actuallyBoostedCount
        self.parentPID = parentPID
        self.gpuPID = gpuPID
        self.contentPID = contentPID
        self.waitingForStableContent = waitingForStableContent
        self.warning = warning
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
    public let targetNiceValue: Int32?
    public let targetScope: AppPriorityTargetScope?
    public let policyKind: AppPriorityPolicyKind?
    public let focusedFirefox: FocusedFirefoxStatusDetails?

    public init(
        state: State,
        boostedCount: Int,
        skippedCount: Int,
        message: String,
        sessionIdentifier: String?,
        targetNiceValue: Int32? = nil,
        targetScope: AppPriorityTargetScope? = nil,
        policyKind: AppPriorityPolicyKind? = nil,
        focusedFirefox: FocusedFirefoxStatusDetails? = nil
    ) {
        self.state = state
        self.boostedCount = boostedCount
        self.skippedCount = skippedCount
        self.message = message
        self.sessionIdentifier = sessionIdentifier
        self.targetNiceValue = targetNiceValue
        self.targetScope = targetScope
        self.policyKind = policyKind
        self.focusedFirefox = focusedFirefox
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
