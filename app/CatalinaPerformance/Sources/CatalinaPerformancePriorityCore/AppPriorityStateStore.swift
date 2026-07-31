import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct AppPriorityRuntimePaths: Equatable {
    public let runtimeRoot: URL
    public let requestingUID: UInt32
    public let publicDirectory: URL
    public let privateDirectory: URL
    public let runtimeStateFile: URL
    public let monitorPIDFile: URL
    public let startLockFile: URL
    public let monitorLockFile: URL
    public let monitorLogFile: URL
    public let stopRequestFile: URL
    public let statusFile: URL

    public init(runtimeRoot: URL, requestingUID: UInt32) {
        self.runtimeRoot = runtimeRoot
        self.requestingUID = requestingUID
        self.publicDirectory = runtimeRoot
            .appendingPathComponent(String(requestingUID), isDirectory: true)
            .appendingPathComponent("app_priority", isDirectory: true)
        self.privateDirectory = publicDirectory.appendingPathComponent("private", isDirectory: true)
        self.runtimeStateFile = privateDirectory.appendingPathComponent("session.json")
        self.monitorPIDFile = privateDirectory.appendingPathComponent("monitor.pid.json")
        self.startLockFile = privateDirectory.appendingPathComponent("start.lock")
        self.monitorLockFile = privateDirectory.appendingPathComponent("monitor.lock")
        self.monitorLogFile = privateDirectory.appendingPathComponent("monitor.log")
        self.stopRequestFile = privateDirectory.appendingPathComponent("stop.request")
        self.statusFile = publicDirectory.appendingPathComponent("status.json")
    }
}

public enum AppPriorityRecordStatus: String, Codable {
    case changed
    case unchanged
    case restored
    case exited
    case mismatched
    case failed
}

public struct AppPriorityRestoreRecord: Codable, Equatable {
    public let identity: AppPriorityProcessIdentity
    public let originalNiceValue: Int32
    public let didChangePriority: Bool
    public var lastObservedStatus: AppPriorityRecordStatus
    public var errorMessage: String?

    public init(identity: AppPriorityProcessIdentity, originalNiceValue: Int32, didChangePriority: Bool, lastObservedStatus: AppPriorityRecordStatus, errorMessage: String?) {
        self.identity = identity
        self.originalNiceValue = originalNiceValue
        self.didChangePriority = didChangePriority
        self.lastObservedStatus = lastObservedStatus
        self.errorMessage = errorMessage.map { String($0.prefix(256)) }
    }
}

public struct AppPriorityMonitorIdentity: Codable, Equatable {
    public let pid: Int32
    public let startSeconds: Int64
    public let startMicroseconds: Int32

    public init(pid: Int32, startSeconds: Int64, startMicroseconds: Int32) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public struct AppPriorityRuntimeState: Codable, Equatable {
    public let version: Int
    public let sessionIdentifier: String
    public let selectedApplication: AppPriorityApplication
    public let requestingUID: UInt32
    public var monitorIdentity: AppPriorityMonitorIdentity?
    public var records: [AppPriorityRestoreRecord]
    public let startedAt: Date

    public init(sessionIdentifier: String, selectedApplication: AppPriorityApplication, requestingUID: UInt32, monitorIdentity: AppPriorityMonitorIdentity?, records: [AppPriorityRestoreRecord], startedAt: Date) {
        self.version = 1
        self.sessionIdentifier = sessionIdentifier
        self.selectedApplication = selectedApplication
        self.requestingUID = requestingUID
        self.monitorIdentity = monitorIdentity
        self.records = records
        self.startedAt = startedAt
    }
}

public final class AppPriorityStateStore {
    public let paths: AppPriorityRuntimePaths
    private let fileManager: FileManager

    public init(runtimeRoot: URL = URL(fileURLWithPath: "/var/run/CatalinaPerformance", isDirectory: true), requestingUID: UInt32, fileManager: FileManager = .default) {
        self.paths = AppPriorityRuntimePaths(runtimeRoot: runtimeRoot, requestingUID: requestingUID)
        self.fileManager = fileManager
    }

    public func prepareDirectories() throws {
        try fileManager.createDirectory(at: paths.publicDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: paths.publicDirectory.path)
        try fileManager.createDirectory(at: paths.privateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: paths.privateDirectory.path)
    }

    public func writeRuntimeState(_ state: AppPriorityRuntimeState) throws {
        try writeJSONAtomically(state, to: paths.runtimeStateFile, permissions: 0o600)
    }

    public func loadRuntimeState() throws -> AppPriorityRuntimeState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppPriorityRuntimeState.self, from: Data(contentsOf: paths.runtimeStateFile))
    }

    public func runtimeStateIfPresent() -> AppPriorityRuntimeState? {
        return try? loadRuntimeState()
    }

    public func writeMonitorIdentity(_ identity: AppPriorityMonitorIdentity) throws {
        try writeJSONAtomically(identity, to: paths.monitorPIDFile, permissions: 0o600)
    }

    public func loadMonitorIdentity() -> AppPriorityMonitorIdentity? {
        guard let data = try? Data(contentsOf: paths.monitorPIDFile) else { return nil }
        return try? JSONDecoder().decode(AppPriorityMonitorIdentity.self, from: data)
    }

    public func writeStatus(_ status: AppPriorityStatus) throws {
        try writeJSONAtomically(status, to: paths.statusFile, permissions: 0o644)
    }

    public func loadStatus() -> AppPriorityStatus? {
        guard let data = try? Data(contentsOf: paths.statusFile) else { return nil }
        return try? JSONDecoder().decode(AppPriorityStatus.self, from: data)
    }

    public func createStopRequest() throws {
        try prepareDirectories()
        let data = Data("stop\n".utf8)
        try writeDataAtomically(data, to: paths.stopRequestFile, permissions: 0o600)
    }

    public func stopRequested() -> Bool {
        return fileManager.fileExists(atPath: paths.stopRequestFile.path)
    }

    public func clearStopRequest() {
        try? fileManager.removeItem(at: paths.stopRequestFile)
    }

    public func removeRuntimeFilesAfterSuccessfulRestore() {
        try? fileManager.removeItem(at: paths.runtimeStateFile)
        try? fileManager.removeItem(at: paths.monitorPIDFile)
        try? fileManager.removeItem(at: paths.stopRequestFile)
    }

    private func writeJSONAtomically<T: Encodable>(_ value: T, to destination: URL, permissions: Int) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try writeDataAtomically(data, to: destination, permissions: permissions)
    }

    private func writeDataAtomically(_ data: Data, to destination: URL, permissions: Int) throws {
        try prepareDirectories()
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: [])
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(permissions))], ofItemAtPath: temporary.path)
            let descriptor = open(temporary.path, O_RDONLY)
            if descriptor >= 0 {
                _ = fsync(descriptor)
                close(descriptor)
            }
            let result = temporary.path.withCString { source in
                destination.path.withCString { target in rename(source, target) }
            }
            if result != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
            }
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(permissions))], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
