import Foundation

public enum BackgroundServiceCategory: String, Codable, CaseIterable {
    case softwareUpdate
    case appStoreUpdates
    case photos
    case mail
    case messagesFaceTime
    case siriSpeech
    case iCloudDrive

    public static let automatic: [BackgroundServiceCategory] = [
        .softwareUpdate,
        .appStoreUpdates,
        .photos,
        .mail,
        .messagesFaceTime,
        .siriSpeech
    ]
}

public enum BackgroundServiceCategoryState: String, Codable {
    case notConfigured
    case pending
    case unsupported
    case skipped
    case capturing
    case suppressing
    case paused
    case degraded
    case resumedByUser
    case restoring
    case restored
    case restoreFailed
}

public enum BackgroundServiceOverallState: String, Codable {
    case off
    case preparing
    case active
    case degraded
    case restoring
    case recoveryRequired
    case restored
}

public enum BackgroundServiceSuppressionMechanism: String, Codable {
    case settings
    case verifiedUserProcessTermination
}

public struct BackgroundServiceTarget: Codable, Equatable, Hashable {
    public let category: BackgroundServiceCategory
    public let launchLabel: String
    public let allowedExecutablePaths: [String]
    public let associatedBundleIdentifiers: [String]
    public let mechanism: BackgroundServiceSuppressionMechanism

    public init(
        category: BackgroundServiceCategory,
        launchLabel: String,
        allowedExecutablePaths: [String],
        associatedBundleIdentifiers: [String],
        mechanism: BackgroundServiceSuppressionMechanism
    ) {
        self.category = category
        self.launchLabel = launchLabel
        self.allowedExecutablePaths = allowedExecutablePaths
        self.associatedBundleIdentifiers = associatedBundleIdentifiers
        self.mechanism = mechanism
    }
}

public struct BackgroundServiceWorkerRecord: Codable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let effectiveUID: UInt32
    public let executablePath: String
    public let processStartSeconds: UInt64
    public let processStartMicroseconds: UInt64
    public let launchLabel: String
    public let wasRunningBeforeSuppression: Bool
    public let didAttemptStop: Bool
    public let didConfirmStop: Bool
    public let didAttemptRestore: Bool
    public let didConfirmRestore: Bool
    public let errorMessage: String?

    public init(
        pid: Int32,
        parentPID: Int32,
        effectiveUID: UInt32,
        executablePath: String,
        processStartSeconds: UInt64,
        processStartMicroseconds: UInt64,
        launchLabel: String,
        wasRunningBeforeSuppression: Bool,
        didAttemptStop: Bool,
        didConfirmStop: Bool,
        didAttemptRestore: Bool,
        didConfirmRestore: Bool,
        errorMessage: String?
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.effectiveUID = effectiveUID
        self.executablePath = executablePath
        self.processStartSeconds = processStartSeconds
        self.processStartMicroseconds = processStartMicroseconds
        self.launchLabel = launchLabel
        self.wasRunningBeforeSuppression = wasRunningBeforeSuppression
        self.didAttemptStop = didAttemptStop
        self.didConfirmStop = didConfirmStop
        self.didAttemptRestore = didAttemptRestore
        self.didConfirmRestore = didConfirmRestore
        self.errorMessage = errorMessage
    }
}

public struct BackgroundServiceUserResume: Codable, Equatable {
    public let reason: String
    public let resumedAt: Date

    public init(reason: String, resumedAt: Date) {
        self.reason = reason
        self.resumedAt = resumedAt
    }
}

public struct BackgroundServiceCategoryRecord: Codable, Equatable {
    public let category: BackgroundServiceCategory
    public let requested: Bool
    public let state: BackgroundServiceCategoryState
    public let note: String?
    public let workers: [BackgroundServiceWorkerRecord]
    public let userResume: BackgroundServiceUserResume?
    public let updatedAt: Date

    public init(
        category: BackgroundServiceCategory,
        requested: Bool,
        state: BackgroundServiceCategoryState,
        note: String?,
        workers: [BackgroundServiceWorkerRecord],
        userResume: BackgroundServiceUserResume?,
        updatedAt: Date
    ) {
        self.category = category
        self.requested = requested
        self.state = state
        self.note = note
        self.workers = workers
        self.userResume = userResume
        self.updatedAt = updatedAt
    }
}

public struct BackgroundServiceSessionRecord: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionIdentifier: String
    public let requestingUID: UInt32
    public let startedAt: Date
    public let completedAt: Date?
    public let categories: [BackgroundServiceCategoryRecord]

    public init(
        schemaVersion: Int = BackgroundServiceSessionRecord.currentSchemaVersion,
        sessionIdentifier: String,
        requestingUID: UInt32,
        startedAt: Date,
        completedAt: Date?,
        categories: [BackgroundServiceCategoryRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.requestingUID = requestingUID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.categories = categories
    }

    public var hasOutstandingRestoration: Bool {
        return categories.contains { category in
            switch category.state {
            case .restoring, .restoreFailed:
                return true
            default:
                return false
            }
        }
    }
}

public struct BackgroundServiceCategoryStatus: Codable, Equatable {
    public let category: BackgroundServiceCategory
    public let state: BackgroundServiceCategoryState
    public let note: String?
    public let updatedAt: Date

    public init(
        category: BackgroundServiceCategory,
        state: BackgroundServiceCategoryState,
        note: String?,
        updatedAt: Date
    ) {
        self.category = category
        self.state = state
        self.note = note
        self.updatedAt = updatedAt
    }
}

public struct BackgroundServiceStatusSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let sessionIdentifier: String?
    public let state: BackgroundServiceOverallState
    public let categories: [BackgroundServiceCategoryStatus]
    public let updatedAt: Date

    public init(
        schemaVersion: Int = BackgroundServiceSessionRecord.currentSchemaVersion,
        sessionIdentifier: String?,
        state: BackgroundServiceOverallState,
        categories: [BackgroundServiceCategoryStatus],
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.state = state
        self.categories = categories
        self.updatedAt = updatedAt
    }
}
