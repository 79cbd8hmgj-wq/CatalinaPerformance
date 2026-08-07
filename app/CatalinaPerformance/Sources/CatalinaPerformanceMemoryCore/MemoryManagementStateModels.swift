import Foundation
import CatalinaPerformancePriorityCore

public struct MemoryDesiredProcess: Codable, Equatable {
    public let identity: AppPriorityProcessIdentity
    public let familyIdentifier: String
    public let requestedNiceValue: Int32

    public init(
        identity: AppPriorityProcessIdentity,
        familyIdentifier: String,
        requestedNiceValue: Int32
    ) {
        self.identity = identity
        self.familyIdentifier = familyIdentifier
        self.requestedNiceValue = requestedNiceValue
    }
}

public struct MemoryDesiredFamily: Codable, Equatable {
    public let identifier: String
    public let displayName: String
    public let bundlePath: String
    public let processes: [MemoryDesiredProcess]

    public init(
        identifier: String,
        displayName: String,
        bundlePath: String,
        processes: [MemoryDesiredProcess]
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.processes = processes
    }
}

public struct MemoryDesiredState: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionIdentifier: String
    public let requestingUID: UInt32
    public let generation: UInt64
    public let shouldStopAndRestore: Bool
    public let families: [MemoryDesiredFamily]

    public init(
        sessionIdentifier: String,
        requestingUID: UInt32,
        generation: UInt64,
        shouldStopAndRestore: Bool,
        families: [MemoryDesiredFamily],
        schemaVersion: Int = MemoryDesiredState.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.requestingUID = requestingUID
        self.generation = generation
        self.shouldStopAndRestore = shouldStopAndRestore
        self.families = families
    }
}

public enum MemoryRestorationState: String, Codable, Equatable {
    case unchanged
    case changed
    case restored
    case exited
    case mismatched
    case failed
}

public struct MemoryManagedProcessRecord: Codable, Equatable {
    public let identity: AppPriorityProcessIdentity
    public let familyIdentifier: String
    public let originalNiceValue: Int32
    public let appliedNiceValue: Int32
    public let didChangePriority: Bool
    public var restorationState: MemoryRestorationState
    public var errorMessage: String?

    public init(
        identity: AppPriorityProcessIdentity,
        familyIdentifier: String,
        originalNiceValue: Int32,
        appliedNiceValue: Int32,
        didChangePriority: Bool,
        restorationState: MemoryRestorationState,
        errorMessage: String?
    ) {
        self.identity = identity
        self.familyIdentifier = familyIdentifier
        self.originalNiceValue = originalNiceValue
        self.appliedNiceValue = appliedNiceValue
        self.didChangePriority = didChangePriority
        self.restorationState = restorationState
        self.errorMessage = errorMessage.map { String($0.prefix(256)) }
    }

    public var requiresRestoration: Bool {
        return didChangePriority &&
            restorationState != .restored &&
            restorationState != .exited
    }
}

public struct MemoryManagedFamilyRecord: Codable, Equatable {
    public let identifier: String
    public let displayName: String
    public let bundlePath: String
    public var processes: [MemoryManagedProcessRecord]

    public init(
        identifier: String,
        displayName: String,
        bundlePath: String,
        processes: [MemoryManagedProcessRecord]
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.processes = processes
    }

    public var hasOutstandingRestoration: Bool {
        return processes.contains { $0.requiresRestoration }
    }
}

public struct MemoryAgentMonitorIdentity: Codable, Equatable {
    public let pid: Int32
    public let startSeconds: Int64
    public let startMicroseconds: Int32

    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int32) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public struct MemoryAgentRuntimeState: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionIdentifier: String
    public let requestingUID: UInt32
    public let startedAt: Date
    public var lastAppliedGeneration: UInt64
    public var monitorIdentity: MemoryAgentMonitorIdentity?
    public var managedFamilies: [MemoryManagedFamilyRecord]

    public init(
        sessionIdentifier: String,
        requestingUID: UInt32,
        startedAt: Date,
        lastAppliedGeneration: UInt64,
        monitorIdentity: MemoryAgentMonitorIdentity?,
        managedFamilies: [MemoryManagedFamilyRecord],
        schemaVersion: Int = MemoryAgentRuntimeState.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.sessionIdentifier = sessionIdentifier
        self.requestingUID = requestingUID
        self.startedAt = startedAt
        self.lastAppliedGeneration = lastAppliedGeneration
        self.monitorIdentity = monitorIdentity
        self.managedFamilies = managedFamilies
    }

    public var hasOutstandingRestoration: Bool {
        return managedFamilies.contains { $0.hasOutstandingRestoration }
    }
}

public struct MemoryAgentStatus: Codable, Equatable {
    public enum State: String, Codable {
        case ready
        case starting
        case monitoring
        case active
        case restoring
        case restorePending
        case restored
        case failed
    }

    public let state: State
    public let sessionIdentifier: String?
    public let managedFamilyCount: Int
    public let managedProcessCount: Int
    public let lastAppliedGeneration: UInt64?
    public let message: String

    public init(
        state: State,
        sessionIdentifier: String?,
        managedFamilyCount: Int,
        managedProcessCount: Int,
        lastAppliedGeneration: UInt64?,
        message: String
    ) {
        self.state = state
        self.sessionIdentifier = sessionIdentifier
        self.managedFamilyCount = managedFamilyCount
        self.managedProcessCount = managedProcessCount
        self.lastAppliedGeneration = lastAppliedGeneration
        self.message = String(message.prefix(512))
    }
}
