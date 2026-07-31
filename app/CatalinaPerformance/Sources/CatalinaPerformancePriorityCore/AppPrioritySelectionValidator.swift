import Foundation
import CatalinaProcessSupport

public enum AppPriorityValidationError: Error, Equatable, CustomStringConvertible {
    case requestingUserIsNotConsoleUser
    case unsafeSelectionPath
    case selectionIsSymlink
    case selectionIsNotRegularFile
    case wrongSelectionOwner
    case unsafeSelectionPermissions
    case malformedSelection
    case unsupportedSelectionVersion
    case featureEnabledWithoutApplication
    case unsafeApplication
    case bundleIdentifierMismatch
    case executablePathMismatch

    public var description: String {
        switch self {
        case .requestingUserIsNotConsoleUser: return "The requesting user is not the console user."
        case .unsafeSelectionPath: return "The selection file path is unsafe."
        case .selectionIsSymlink: return "The selection file may not be a symbolic link."
        case .selectionIsNotRegularFile: return "The selection file is not a regular file."
        case .wrongSelectionOwner: return "The selection file has the wrong owner."
        case .unsafeSelectionPermissions: return "The selection file permissions are unsafe."
        case .malformedSelection: return "The selection file is malformed."
        case .unsupportedSelectionVersion: return "The selection file version is unsupported."
        case .featureEnabledWithoutApplication: return "App Priority is enabled without an application."
        case .unsafeApplication: return "The selected application is unsafe or unavailable."
        case .bundleIdentifierMismatch: return "The selected application bundle identifier does not match."
        case .executablePathMismatch: return "The selected application executable does not match."
        }
    }
}

public struct AppPriorityFileMetadata: Equatable {
    public let ownerUID: UInt32
    public let mode: UInt32
    public let size: UInt64
    public let isRegularFile: Bool
    public let isDirectory: Bool
    public let isSymbolicLink: Bool

    public init(ownerUID: UInt32, mode: UInt32, size: UInt64, isRegularFile: Bool, isDirectory: Bool, isSymbolicLink: Bool) {
        self.ownerUID = ownerUID
        self.mode = mode
        self.size = size
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }
}

public protocol AppPriorityFileMetadataProviding {
    func metadata(at url: URL) throws -> AppPriorityFileMetadata
}

public struct DarwinAppPriorityFileMetadataProvider: AppPriorityFileMetadataProviding {
    public init() {}

    public func metadata(at url: URL) throws -> AppPriorityFileMetadata {
        var info = CPFileInfo()
        let result = url.path.withCString { cp_lstat_path($0, &info) }
        guard result == 0 else { throw AppPriorityValidationError.unsafeSelectionPath }
        return AppPriorityFileMetadata(
            ownerUID: UInt32(info.ownerUid),
            mode: info.mode,
            size: info.size,
            isRegularFile: info.isRegularFile != 0,
            isDirectory: info.isDirectory != 0,
            isSymbolicLink: info.isSymbolicLink != 0
        )
    }
}

public struct ValidatedAppPrioritySelection: Equatable {
    public let enabled: Bool
    public let application: AppPriorityApplication?
    public let requestingUID: UInt32

    public init(enabled: Bool, application: AppPriorityApplication?, requestingUID: UInt32) {
        self.enabled = enabled
        self.application = application
        self.requestingUID = requestingUID
    }
}

public final class AppPrioritySelectionValidator {
    private let fileManager: FileManager
    private let metadataProvider: AppPriorityFileMetadataProviding

    public init(fileManager: FileManager = .default, metadataProvider: AppPriorityFileMetadataProviding = DarwinAppPriorityFileMetadataProvider()) {
        self.fileManager = fileManager
        self.metadataProvider = metadataProvider
    }

    public func validate(
        selectionFileURL: URL,
        requestingUID: UInt32,
        consoleUID: UInt32,
        expectedHomeDirectory: URL
    ) throws -> ValidatedAppPrioritySelection {
        guard requestingUID == consoleUID else {
            throw AppPriorityValidationError.requestingUserIsNotConsoleUser
        }

        let expectedURL = expectedHomeDirectory
            .appendingPathComponent("Library/Application Support/CatalinaPerformance/app_priority", isDirectory: true)
            .appendingPathComponent("selection.json")
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let suppliedURL = selectionFileURL.standardizedFileURL
        guard suppliedURL.path == expectedURL.path else {
            throw AppPriorityValidationError.unsafeSelectionPath
        }

        let metadata: AppPriorityFileMetadata
        do {
            metadata = try metadataProvider.metadata(at: suppliedURL)
        } catch let error as AppPriorityValidationError {
            throw error
        } catch {
            throw AppPriorityValidationError.unsafeSelectionPath
        }
        if metadata.isSymbolicLink { throw AppPriorityValidationError.selectionIsSymlink }
        if !metadata.isRegularFile { throw AppPriorityValidationError.selectionIsNotRegularFile }
        if metadata.ownerUID != requestingUID { throw AppPriorityValidationError.wrongSelectionOwner }
        if (metadata.mode & 0o022) != 0 { throw AppPriorityValidationError.unsafeSelectionPermissions }
        if metadata.size == 0 || metadata.size > 65_536 { throw AppPriorityValidationError.malformedSelection }

        let selection: AppPrioritySelection
        do {
            selection = try JSONDecoder().decode(AppPrioritySelection.self, from: Data(contentsOf: suppliedURL))
        } catch {
            throw AppPriorityValidationError.malformedSelection
        }
        guard selection.version == 1 else { throw AppPriorityValidationError.unsupportedSelectionVersion }
        guard selection.enabled else {
            return ValidatedAppPrioritySelection(enabled: false, application: nil, requestingUID: requestingUID)
        }
        guard let application = selection.application else {
            throw AppPriorityValidationError.featureEnabledWithoutApplication
        }

        let validatedApplication = try validateApplication(application)
        return ValidatedAppPrioritySelection(enabled: true, application: validatedApplication, requestingUID: requestingUID)
    }

    private func validateApplication(_ application: AppPriorityApplication) throws -> AppPriorityApplication {
        guard !AppPriorityApplicationFilter.isExcluded(bundleIdentifier: application.bundleIdentifier, displayName: application.displayName) else {
            throw AppPriorityValidationError.unsafeApplication
        }

        let canonicalBundle = URL(fileURLWithPath: application.bundlePath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalBundle.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppPriorityValidationError.unsafeApplication
        }

        let infoURL = canonicalBundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let actualIdentifier = dictionary["CFBundleIdentifier"] as? String,
              let executableName = dictionary["CFBundleExecutable"] as? String,
              !actualIdentifier.isEmpty,
              !executableName.isEmpty else {
            throw AppPriorityValidationError.unsafeApplication
        }
        guard actualIdentifier == application.bundleIdentifier else {
            throw AppPriorityValidationError.bundleIdentifierMismatch
        }

        let declaredExecutable = canonicalBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let savedExecutable = URL(fileURLWithPath: application.executablePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard declaredExecutable.path == savedExecutable.path,
              fileManager.isExecutableFile(atPath: declaredExecutable.path) else {
            throw AppPriorityValidationError.executablePathMismatch
        }

        return AppPriorityApplication(
            displayName: application.displayName,
            bundleIdentifier: actualIdentifier,
            bundlePath: canonicalBundle.path,
            executablePath: declaredExecutable.path
        )
    }
}
