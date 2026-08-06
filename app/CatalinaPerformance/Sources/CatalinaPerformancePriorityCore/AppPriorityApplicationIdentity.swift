import Foundation

public struct AppPriorityBundleMetadata: Equatable {
    public let bundleIdentifier: String
    public let executableName: String

    public init(bundleIdentifier: String, executableName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
    }
}

public protocol AppPriorityBundleMetadataProviding {
    func metadata(bundleURL: URL) -> AppPriorityBundleMetadata?
}

public struct FoundationAppPriorityBundleMetadataProvider: AppPriorityBundleMetadataProviding {
    public init() {}

    public func metadata(bundleURL: URL) -> AppPriorityBundleMetadata? {
        if let bundle = Bundle(url: bundleURL),
           let identifier = bundle.bundleIdentifier,
           let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
           !identifier.isEmpty,
           !executable.isEmpty {
            return AppPriorityBundleMetadata(bundleIdentifier: identifier, executableName: executable)
        }

        let infoURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = propertyList as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String,
              let executable = dictionary["CFBundleExecutable"] as? String,
              !identifier.isEmpty,
              !executable.isEmpty else {
            return nil
        }
        return AppPriorityBundleMetadata(bundleIdentifier: identifier, executableName: executable)
    }
}

public enum AppPriorityApplicationIdentityError: Error, Equatable {
    case bundleMetadataUnavailable
    case bundleIdentifierMismatch
    case executableMissing
}

public struct AppPriorityApplicationCanonicalizer {
    private let metadataProvider: AppPriorityBundleMetadataProviding
    private let fileManager: FileManager

    public init(
        metadataProvider: AppPriorityBundleMetadataProviding = FoundationAppPriorityBundleMetadataProvider(),
        fileManager: FileManager = .default
    ) {
        self.metadataProvider = metadataProvider
        self.fileManager = fileManager
    }

    public func canonicalApplication(
        displayName: String,
        bundleIdentifier: String,
        bundleURL: URL
    ) throws -> AppPriorityApplication {
        let canonicalBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard let metadata = metadataProvider.metadata(bundleURL: canonicalBundle) else {
            throw AppPriorityApplicationIdentityError.bundleMetadataUnavailable
        }
        guard metadata.bundleIdentifier == bundleIdentifier else {
            throw AppPriorityApplicationIdentityError.bundleIdentifierMismatch
        }
        let executable = canonicalBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(metadata.executableName, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: executable.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw AppPriorityApplicationIdentityError.executableMissing
        }
        return AppPriorityApplication(
            displayName: displayName,
            bundleIdentifier: metadata.bundleIdentifier,
            bundlePath: canonicalBundle.path,
            executablePath: executable.path
        )
    }

    public func migrate(_ application: AppPriorityApplication) throws -> AppPriorityApplication {
        return try canonicalApplication(
            displayName: application.displayName,
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: URL(fileURLWithPath: application.bundlePath, isDirectory: true)
        )
    }

    public func deduplicate(_ applications: [AppPriorityApplication]) -> [AppPriorityApplication] {
        var values: [String: AppPriorityApplication] = [:]
        for application in applications {
            let normalized = (try? migrate(application)) ?? application
            let key = normalized.bundleIdentifier.lowercased() + "\u{0}" + normalized.bundlePath
            if values[key] == nil {
                values[key] = normalized
            }
        }
        return values.values.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if comparison == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return comparison == .orderedAscending
        }
    }
}
