import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct MemoryAgentRuntimePaths: Equatable {
    public let runtimeRoot: URL
    public let requestingUID: UInt32
    public let publicDirectory: URL
    public let privateDirectory: URL
    public let runtimeStateFile: URL
    public let monitorIdentityFile: URL
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
            .appendingPathComponent("memory_management", isDirectory: true)
        self.privateDirectory = publicDirectory.appendingPathComponent("private", isDirectory: true)
        self.runtimeStateFile = privateDirectory.appendingPathComponent("session.json")
        self.monitorIdentityFile = privateDirectory.appendingPathComponent("monitor.pid.json")
        self.startLockFile = privateDirectory.appendingPathComponent("start.lock")
        self.monitorLockFile = privateDirectory.appendingPathComponent("monitor.lock")
        self.monitorLogFile = privateDirectory.appendingPathComponent("monitor.log")
        self.stopRequestFile = privateDirectory.appendingPathComponent("stop.request")
        self.statusFile = publicDirectory.appendingPathComponent("status.json")
    }
}

public enum MemoryAgentStateStoreError: Error, Equatable {
    case fileTooLarge
    case corruptState
    case unsupportedSchema(Int)
    case unresolvedRestoration
}

public protocol MemoryAgentStateStoring: AnyObject {
    var paths: MemoryAgentRuntimePaths { get }
    func prepareDirectories() throws
    func writeRuntimeState(_ state: MemoryAgentRuntimeState) throws
    func loadRuntimeState() throws -> MemoryAgentRuntimeState
    func runtimeStateIfPresent() -> MemoryAgentRuntimeState?
    func writeStatus(_ status: MemoryAgentStatus) throws
    func loadStatus() -> MemoryAgentStatus?
    func writeMonitorIdentity(_ identity: MemoryAgentMonitorIdentity) throws
    func loadMonitorIdentity() -> MemoryAgentMonitorIdentity?
    func createStopRequest() throws
    func stopRequested() -> Bool
    func clearStopRequest()
    func removeRuntimeFilesAfterSuccessfulRestore()
}

public final class MemoryAgentStateStore: MemoryAgentStateStoring {
    public static let maximumFileSize = 1_048_576

    public let paths: MemoryAgentRuntimePaths
    private let fileManager: FileManager

    public init(
        runtimeRoot: URL = URL(fileURLWithPath: "/var/run/CatalinaPerformance", isDirectory: true),
        requestingUID: UInt32,
        fileManager: FileManager = .default
    ) {
        self.paths = MemoryAgentRuntimePaths(runtimeRoot: runtimeRoot, requestingUID: requestingUID)
        self.fileManager = fileManager
    }

    public func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: paths.publicDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: paths.publicDirectory.path
        )
        try fileManager.createDirectory(
            at: paths.privateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: paths.privateDirectory.path
        )
    }

    public func writeRuntimeState(_ state: MemoryAgentRuntimeState) throws {
        guard state.schemaVersion == MemoryAgentRuntimeState.currentSchemaVersion else {
            throw MemoryAgentStateStoreError.unsupportedSchema(state.schemaVersion)
        }
        try writeJSONAtomically(state, to: paths.runtimeStateFile, permissions: 0o600)
    }

    public func loadRuntimeState() throws -> MemoryAgentRuntimeState {
        let data = try readData(paths.runtimeStateFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state: MemoryAgentRuntimeState
        do {
            state = try decoder.decode(MemoryAgentRuntimeState.self, from: data)
        } catch {
            throw MemoryAgentStateStoreError.corruptState
        }
        guard state.schemaVersion == MemoryAgentRuntimeState.currentSchemaVersion else {
            throw MemoryAgentStateStoreError.unsupportedSchema(state.schemaVersion)
        }
        return state
    }

    public func runtimeStateIfPresent() -> MemoryAgentRuntimeState? {
        guard fileManager.fileExists(atPath: paths.runtimeStateFile.path) else { return nil }
        return try? loadRuntimeState()
    }

    public func writeStatus(_ status: MemoryAgentStatus) throws {
        try writeJSONAtomically(status, to: paths.statusFile, permissions: 0o644)
    }

    public func loadStatus() -> MemoryAgentStatus? {
        guard fileManager.fileExists(atPath: paths.statusFile.path) else { return nil }
        guard let data = try? readData(paths.statusFile) else { return nil }
        return try? JSONDecoder().decode(MemoryAgentStatus.self, from: data)
    }

    public func writeMonitorIdentity(_ identity: MemoryAgentMonitorIdentity) throws {
        try writeJSONAtomically(identity, to: paths.monitorIdentityFile, permissions: 0o600)
    }

    public func loadMonitorIdentity() -> MemoryAgentMonitorIdentity? {
        guard fileManager.fileExists(atPath: paths.monitorIdentityFile.path) else { return nil }
        guard let data = try? readData(paths.monitorIdentityFile) else { return nil }
        return try? JSONDecoder().decode(MemoryAgentMonitorIdentity.self, from: data)
    }

    public func createStopRequest() throws {
        try prepareDirectories()
        try writeDataAtomically(Data("stop\n".utf8), to: paths.stopRequestFile, permissions: 0o600)
    }

    public func stopRequested() -> Bool {
        return fileManager.fileExists(atPath: paths.stopRequestFile.path)
    }

    public func clearStopRequest() {
        try? fileManager.removeItem(at: paths.stopRequestFile)
    }

    public func removeRuntimeFilesAfterSuccessfulRestore() {
        guard let state = runtimeStateIfPresent(), state.hasOutstandingRestoration else {
            try? fileManager.removeItem(at: paths.runtimeStateFile)
            try? fileManager.removeItem(at: paths.monitorIdentityFile)
            try? fileManager.removeItem(at: paths.stopRequestFile)
            return
        }
    }

    private func readData(_ url: URL) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue <= 0 || size.intValue > Self.maximumFileSize {
            throw MemoryAgentStateStoreError.fileTooLarge
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func writeJSONAtomically<T: Encodable>(_ value: T, to destination: URL, permissions: Int) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard !data.isEmpty, data.count <= Self.maximumFileSize else {
            throw MemoryAgentStateStoreError.fileTooLarge
        }
        try writeDataAtomically(data, to: destination, permissions: permissions)
    }

    private func writeDataAtomically(_ data: Data, to destination: URL, permissions: Int) throws {
        try prepareDirectories()
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: [])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(permissions))],
                ofItemAtPath: temporary.path
            )
            let descriptor = open(temporary.path, O_RDONLY)
            if descriptor >= 0 {
                _ = fsync(descriptor)
                close(descriptor)
            }
            let result = temporary.path.withCString { source in
                destination.path.withCString { target in
                    rename(source, target)
                }
            }
            if result != 0 {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: destination.path]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(permissions))],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
