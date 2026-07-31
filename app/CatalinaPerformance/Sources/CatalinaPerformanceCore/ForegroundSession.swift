import Foundation

public struct ForegroundApplication: Equatable {
    public let displayName: String
    public let bundleIdentifier: String
    public let isRunning: Bool
    public let isRegularGUIApplication: Bool

    public init(displayName: String, bundleIdentifier: String, isRunning: Bool, isRegularGUIApplication: Bool) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
        self.isRegularGUIApplication = isRegularGUIApplication
    }
}

public enum ForegroundApplicationFilter {
    private static let excludedBundleIdentifiers: Set<String> = [
        "local.CatalinaPerformance",
        "org.swift.CatalinaPerformance",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.WindowServer",
        "com.apple.loginwindow"
    ]

    public static func isValid(bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty,
              !bundleIdentifier.hasPrefix("."),
              !bundleIdentifier.hasSuffix("."),
              !bundleIdentifier.contains("..") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        return bundleIdentifier.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func isExcluded(bundleIdentifier: String, displayName: String) -> Bool {
        if excludedBundleIdentifiers.contains(bundleIdentifier) { return true }
        if bundleIdentifier.hasPrefix("com.googlecode.iterm2.") { return true }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName == "catalinaperformance" || normalizedName == "terminal" || normalizedName == "iterm" || normalizedName == "iterm2"
    }

    public static func eligibleApplications(from applications: [ForegroundApplication]) -> [ForegroundApplication] {
        var seen = Set<String>()
        return applications
            .filter { application in
                guard application.isRunning,
                      application.isRegularGUIApplication,
                      isValid(bundleIdentifier: application.bundleIdentifier),
                      !isExcluded(bundleIdentifier: application.bundleIdentifier, displayName: application.displayName),
                      !seen.contains(application.bundleIdentifier) else {
                    return false
                }
                seen.insert(application.bundleIdentifier)
                return true
            }
            .sorted { lhs, rhs in
                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if comparison == .orderedSame {
                    return lhs.bundleIdentifier < rhs.bundleIdentifier
                }
                return comparison == .orderedAscending
            }
    }
}

public struct ForegroundSessionPreferences: Equatable {
    public static let featureEnabledKey = "advanced.foregroundSession.enabled"
    public static let disableFinderAnimationsKey = "advanced.foregroundSession.disableFinderAnimations"
    public static let shortenDockAnimationsKey = "advanced.foregroundSession.shortenDockAnimations"
    public static let disableWindowAnimationsKey = "advanced.foregroundSession.disableWindowAnimations"
    public static let selectedBundleIdentifiersKey = "advanced.foregroundSession.selectedBundleIdentifiers"

    public var featureEnabled: Bool
    public var disableFinderAnimations: Bool
    public var shortenDockAnimations: Bool
    public var disableWindowAnimations: Bool
    public var selectedBundleIdentifiers: [String]

    public init(
        featureEnabled: Bool,
        disableFinderAnimations: Bool,
        shortenDockAnimations: Bool,
        disableWindowAnimations: Bool,
        selectedBundleIdentifiers: [String]
    ) {
        self.featureEnabled = featureEnabled
        self.disableFinderAnimations = disableFinderAnimations
        self.shortenDockAnimations = shortenDockAnimations
        self.disableWindowAnimations = disableWindowAnimations
        self.selectedBundleIdentifiers = selectedBundleIdentifiers
    }

    public static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            featureEnabledKey: false,
            disableFinderAnimationsKey: true,
            shortenDockAnimationsKey: true,
            disableWindowAnimationsKey: true,
            selectedBundleIdentifiersKey: [String]()
        ])
    }

    public static func load(from defaults: UserDefaults = .standard) -> ForegroundSessionPreferences {
        return ForegroundSessionPreferences(
            featureEnabled: defaults.bool(forKey: featureEnabledKey),
            disableFinderAnimations: defaults.bool(forKey: disableFinderAnimationsKey),
            shortenDockAnimations: defaults.bool(forKey: shortenDockAnimationsKey),
            disableWindowAnimations: defaults.bool(forKey: disableWindowAnimationsKey),
            selectedBundleIdentifiers: defaults.stringArray(forKey: selectedBundleIdentifiersKey) ?? []
        )
    }

    public var safeSelectedBundleIdentifiers: [String] {
        var seen = Set<String>()
        return selectedBundleIdentifiers
            .filter { identifier in
                ForegroundApplicationFilter.isValid(bundleIdentifier: identifier)
                    && !ForegroundApplicationFilter.isExcluded(bundleIdentifier: identifier, displayName: "")
                    && seen.insert(identifier).inserted
            }
            .sorted()
    }

    public var serializedEnvironment: String {
        var lines = [
            "FOREGROUND_SESSION_ENABLED=\(featureEnabled ? 1 : 0)",
            "DISABLE_FINDER_ANIMATIONS=\(disableFinderAnimations ? 1 : 0)",
            "SHORTEN_DOCK_ANIMATIONS=\(shortenDockAnimations ? 1 : 0)",
            "DISABLE_WINDOW_ANIMATIONS=\(disableWindowAnimations ? 1 : 0)"
        ]
        lines.append(contentsOf: safeSelectedBundleIdentifiers.map { "SELECTED_BUNDLE_ID=\($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    public func write(to url: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try serializedEnvironment.write(to: temporaryURL, atomically: false, encoding: .utf8)
        _ = try String(contentsOf: temporaryURL, encoding: .utf8)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        return url
    }
}

public struct ForegroundSessionSummary: Equatable {
    public let sessionActive: Bool
    public let selected: Int
    public let runningBefore: Int
    public let confirmedClosed: Int
    public let skipped: Int
    public let pendingRelaunch: Int
    public let relaunchFailed: Int
    public let uiPreferencesRecorded: Int
    public let uiRestorePending: Int

    public static let empty = ForegroundSessionSummary(
        sessionActive: false,
        selected: 0,
        runningBefore: 0,
        confirmedClosed: 0,
        skipped: 0,
        pendingRelaunch: 0,
        relaunchFailed: 0,
        uiPreferencesRecorded: 0,
        uiRestorePending: 0
    )

    public static func parse(_ output: String) -> ForegroundSessionSummary {
        var values: [String: Int] = [:]
        output.split(whereSeparator: { $0.isNewline }).forEach { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return }
            values[String(parts[0])] = value
        }
        return ForegroundSessionSummary(
            sessionActive: values["session_active"] == 1,
            selected: values["selected"] ?? 0,
            runningBefore: values["running_before"] ?? 0,
            confirmedClosed: values["confirmed_closed"] ?? 0,
            skipped: values["skipped"] ?? 0,
            pendingRelaunch: values["pending_relaunch"] ?? 0,
            relaunchFailed: values["relaunch_failed"] ?? 0,
            uiPreferencesRecorded: values["ui_preferences_recorded"] ?? 0,
            uiRestorePending: values["ui_restore_pending"] ?? 0
        )
    }
}
