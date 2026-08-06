import Foundation

public enum BackgroundServiceCatalogError: Error, Equatable, CustomStringConvertible {
    case emptyLaunchLabel
    case emptyExecutablePaths
    case nonAbsoluteExecutablePath(String)
    case wildcardIdentity(String)
    case protectedLaunchLabel(String)
    case protectedExecutablePath(String)
    case missingAssociatedApplication(BackgroundServiceCategory)

    public var description: String {
        switch self {
        case .emptyLaunchLabel:
            return "Background service launch label is empty."
        case .emptyExecutablePaths:
            return "Background service target has no executable path."
        case .nonAbsoluteExecutablePath(let path):
            return "Background service executable path is not absolute: \(path)"
        case .wildcardIdentity(let value):
            return "Background service identity contains a wildcard: \(value)"
        case .protectedLaunchLabel(let label):
            return "Protected launch label cannot be suppressed: \(label)"
        case .protectedExecutablePath(let path):
            return "Protected executable cannot be suppressed: \(path)"
        case .missingAssociatedApplication(let category):
            return "Background service category lacks a verified resume application: \(category.rawValue)"
        }
    }
}

public enum BackgroundServiceProtectedPolicy {
    private static let protectedLaunchLabels: Set<String> = [
        "com.apple.securityd",
        "com.apple.trustd",
        "com.apple.accountsd",
        "com.apple.cloudd",
        "com.apple.apsd",
        "com.apple.sharingd",
        "com.apple.rapportd",
        "com.apple.mDNSResponder",
        "com.apple.configd",
        "com.apple.airportd",
        "com.apple.Finder",
        "com.apple.Dock.agent",
        "com.apple.WindowServer",
        "com.apple.SystemUIServer.agent",
        "com.apple.loginwindow",
        "com.apple.launchd",
        "com.apple.audio.coreaudiod",
        "com.apple.diagnosticd",
        "com.apple.ReportCrash",
        "com.apple.logd"
    ].map { $0.lowercased() }.reduce(into: Set<String>()) { $0.insert($1) }

    private static let protectedExecutableBasenames: Set<String> = [
        "securityd", "trustd", "accountsd", "cloudd", "apsd", "sharingd",
        "rapportd", "mDNSResponder", "configd", "airportd", "Finder", "Dock",
        "WindowServer", "SystemUIServer", "loginwindow", "launchd", "coreaudiod",
        "diagnosticd", "ReportCrash", "logd", "VoiceOver", "universalaccessd"
    ].map { $0.lowercased() }.reduce(into: Set<String>()) { $0.insert($1) }

    public static func validate(target: BackgroundServiceTarget) throws {
        let label = target.launchLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw BackgroundServiceCatalogError.emptyLaunchLabel }
        guard !label.contains("*") else { throw BackgroundServiceCatalogError.wildcardIdentity(label) }
        guard !protectedLaunchLabels.contains(label.lowercased()) else {
            throw BackgroundServiceCatalogError.protectedLaunchLabel(label)
        }
        guard !target.allowedExecutablePaths.isEmpty else {
            throw BackgroundServiceCatalogError.emptyExecutablePaths
        }

        for rawPath in target.allowedExecutablePaths {
            guard rawPath.hasPrefix("/") else {
                throw BackgroundServiceCatalogError.nonAbsoluteExecutablePath(rawPath)
            }
            guard !rawPath.contains("*") else {
                throw BackgroundServiceCatalogError.wildcardIdentity(rawPath)
            }
            let canonical = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            let basename = URL(fileURLWithPath: canonical).lastPathComponent.lowercased()
            guard !protectedExecutableBasenames.contains(basename) else {
                throw BackgroundServiceCatalogError.protectedExecutablePath(canonical)
            }
        }

        if target.mechanism == .verifiedUserProcessTermination && target.associatedBundleIdentifiers.isEmpty {
            throw BackgroundServiceCatalogError.missingAssociatedApplication(target.category)
        }
    }
}

public struct CatalinaBackgroundServiceCatalog: Equatable {
    public let targets: [BackgroundServiceTarget]
    public let unsupportedCategories: Set<BackgroundServiceCategory>

    public init(targets: [BackgroundServiceTarget], unsupportedCategories: Set<BackgroundServiceCategory>) {
        self.targets = targets
        self.unsupportedCategories = unsupportedCategories
    }

    public func targets(for category: BackgroundServiceCategory) -> [BackgroundServiceTarget] {
        return targets.filter { $0.category == category }
    }

    public func workerTargets(for category: BackgroundServiceCategory) -> [BackgroundServiceTarget] {
        return targets.filter {
            $0.category == category && $0.mechanism == .verifiedUserProcessTermination
        }
    }

    public func category(forAssociatedBundleIdentifier bundleIdentifier: String) -> BackgroundServiceCategory? {
        return targets.first(where: {
            $0.associatedBundleIdentifiers.contains(bundleIdentifier)
        })?.category
    }

    public static let current: CatalinaBackgroundServiceCatalog = {
        let photosBundle = "com.apple.Photos"
        let mailBundle = "com.apple.mail"
        let messagesBundles = ["com.apple.iChat", "com.apple.FaceTime"]
        let appStoreBundle = "com.apple.AppStore"
        let systemPreferencesBundle = "com.apple.systempreferences"

        let verifiedTargets: [BackgroundServiceTarget] = [
            BackgroundServiceTarget(
                category: .softwareUpdate,
                launchLabel: "com.apple.SoftwareUpdateNotificationManager",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/SoftwareUpdate.framework/Resources/SoftwareUpdateNotificationManager.app/Contents/MacOS/SoftwareUpdateNotificationManager"
                ],
                associatedBundleIdentifiers: [systemPreferencesBundle],
                mechanism: .settings
            ),
            BackgroundServiceTarget(
                category: .appStoreUpdates,
                launchLabel: "com.apple.appstoreagent",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/AppStoreDaemon.framework/Support/appstoreagent"
                ],
                associatedBundleIdentifiers: [appStoreBundle],
                mechanism: .settings
            ),
            BackgroundServiceTarget(
                category: .photos,
                launchLabel: "com.apple.photolibraryd",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/PhotoLibraryServices.framework/Versions/A/Support/photolibraryd"
                ],
                associatedBundleIdentifiers: [photosBundle],
                mechanism: .verifiedUserProcessTermination
            ),
            BackgroundServiceTarget(
                category: .photos,
                launchLabel: "com.apple.cloudphotod",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/CloudPhotoLibrary.framework/Versions/A/Support/cloudphotod"
                ],
                associatedBundleIdentifiers: [photosBundle],
                mechanism: .verifiedUserProcessTermination
            ),
            BackgroundServiceTarget(
                category: .photos,
                launchLabel: "com.apple.photoanalysisd",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd"
                ],
                associatedBundleIdentifiers: [photosBundle],
                mechanism: .verifiedUserProcessTermination
            ),
            BackgroundServiceTarget(
                category: .photos,
                launchLabel: "com.apple.mediaanalysisd",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/VideoProcessing.framework/Versions/A/mediaanalysisd"
                ],
                associatedBundleIdentifiers: [photosBundle],
                mechanism: .verifiedUserProcessTermination
            ),
            BackgroundServiceTarget(
                category: .mail,
                launchLabel: "com.apple.email.maild",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/EmailDaemon.framework/Versions/A/maild"
                ],
                associatedBundleIdentifiers: [mailBundle],
                mechanism: .verifiedUserProcessTermination
            ),
            BackgroundServiceTarget(
                category: .mail,
                launchLabel: "com.apple.mdworker.mail",
                allowedExecutablePaths: [
                    "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mdworker_shared"
                ],
                associatedBundleIdentifiers: [mailBundle],
                mechanism: .verifiedUserProcessTermination
            ),
            BackgroundServiceTarget(
                category: .messagesFaceTime,
                launchLabel: "com.apple.imagent",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/IMCore.framework/imagent.app/Contents/MacOS/imagent"
                ],
                associatedBundleIdentifiers: messagesBundles,
                mechanism: .verifiedUserProcessTermination
            ),
            BackgroundServiceTarget(
                category: .messagesFaceTime,
                launchLabel: "com.apple.cmfsyncagent",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/CommunicationsFilter.framework/CMFSyncAgent"
                ],
                associatedBundleIdentifiers: messagesBundles,
                mechanism: .verifiedUserProcessTermination
            ),
            BackgroundServiceTarget(
                category: .messagesFaceTime,
                launchLabel: "com.apple.CallHistorySyncHelper",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/CallHistory.framework/Support/CallHistorySyncHelper"
                ],
                associatedBundleIdentifiers: messagesBundles,
                mechanism: .verifiedUserProcessTermination
            ),
            BackgroundServiceTarget(
                category: .messagesFaceTime,
                launchLabel: "com.apple.telephonyutilities.callservicesd",
                allowedExecutablePaths: [
                    "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd"
                ],
                associatedBundleIdentifiers: messagesBundles,
                mechanism: .verifiedUserProcessTermination
            )
        ]

        for target in verifiedTargets {
            precondition((try? BackgroundServiceProtectedPolicy.validate(target: target)) != nil)
        }

        return CatalinaBackgroundServiceCatalog(
            targets: verifiedTargets,
            unsupportedCategories: [.siriSpeech, .iCloudDrive]
        )
    }()
}
