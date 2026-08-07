import Foundation
import CatalinaPerformancePriorityCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum MemoryDesiredStateStoreError: Error, Equatable {
    case symbolicLinkRejected
    case fileTooLarge
    case malformedState
    case unsupportedSchema(Int)
    case staleGeneration
    case unsafePath
    case wrongOwner
    case unsafePermissions
    case requestingUserIsNotConsoleUser
    case unsafeDesiredState
}

public protocol MemoryDesiredStateStoring: AnyObject {
    func load() throws -> MemoryDesiredState?
    func save(_ state: MemoryDesiredState) throws
    func remove() throws
}

public final class MemoryDesiredStateStore: MemoryDesiredStateStoring {
    public static let maximumFileSize = 1_048_576
    public static let maximumFamilyCount = 3
    public static let maximumProcessCount = 256

    public let directoryURL: URL
    public let desiredStateURL: URL

    private let fileManager: FileManager
    private let metadataProvider: AppPriorityFileMetadataProviding

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        metadataProvider: AppPriorityFileMetadataProviding = DarwinAppPriorityFileMetadataProvider()
    ) {
        self.directoryURL = directoryURL
        self.desiredStateURL = directoryURL.appendingPathComponent("desired-state.json")
        self.fileManager = fileManager
        self.metadataProvider = metadataProvider
    }

    public func load() throws -> MemoryDesiredState? {
        try rejectSymbolicLinkIfPresent(at: directoryURL)
        guard fileManager.fileExists(atPath: desiredStateURL.path) else { return nil }
        try rejectSymbolicLink(at: desiredStateURL)
        let attributes = try fileManager.attributesOfItem(atPath: desiredStateURL.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue <= 0 || size.intValue > Self.maximumFileSize {
            throw MemoryDesiredStateStoreError.fileTooLarge
        }
        let data = try Data(contentsOf: desiredStateURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state: MemoryDesiredState
        do {
            state = try decoder.decode(MemoryDesiredState.self, from: data)
        } catch {
            throw MemoryDesiredStateStoreError.malformedState
        }
        try validateShape(state)
        return state
    }

    public func save(_ state: MemoryDesiredState) throws {
        try validateShape(state)
        if let existing = try load(),
           existing.sessionIdentifier == state.sessionIdentifier,
           state.generation <= existing.generation {
            throw MemoryDesiredStateStoreError.staleGeneration
        }
        try prepareDirectory()
        try rejectSymbolicLinkIfPresent(at: desiredStateURL)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard !data.isEmpty, data.count <= Self.maximumFileSize else {
            throw MemoryDesiredStateStoreError.fileTooLarge
        }
        try writeAtomically(data, to: desiredStateURL, permissions: 0o600)
    }

    public func remove() throws {
        guard fileManager.fileExists(atPath: desiredStateURL.path) else { return }
        try rejectSymbolicLink(at: desiredStateURL)
        try fileManager.removeItem(at: desiredStateURL)
    }

    public func loadValidatedForAgent(
        requestingUID: UInt32,
        consoleUID: UInt32,
        expectedHomeDirectory: URL
    ) throws -> MemoryDesiredState {
        guard requestingUID > 0, requestingUID == consoleUID else {
            throw MemoryDesiredStateStoreError.requestingUserIsNotConsoleUser
        }

        let expected = expectedHomeDirectory
            .appendingPathComponent("Library/Application Support/CatalinaPerformance/memory_management", isDirectory: true)
            .appendingPathComponent("desired-state.json")
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let supplied = desiredStateURL.standardizedFileURL
        guard supplied.path == expected.path else {
            throw MemoryDesiredStateStoreError.unsafePath
        }

        let metadata = try metadataProvider.metadata(at: supplied)
        if metadata.isSymbolicLink || !metadata.isRegularFile {
            throw MemoryDesiredStateStoreError.symbolicLinkRejected
        }
        if metadata.ownerUID != requestingUID {
            throw MemoryDesiredStateStoreError.wrongOwner
        }
        if (metadata.mode & 0o022) != 0 {
            throw MemoryDesiredStateStoreError.unsafePermissions
        }
        if metadata.size == 0 || metadata.size > UInt64(Self.maximumFileSize) {
            throw MemoryDesiredStateStoreError.fileTooLarge
        }

        guard let state = try load() else {
            throw MemoryDesiredStateStoreError.malformedState
        }
        guard state.requestingUID == requestingUID else {
            throw MemoryDesiredStateStoreError.unsafeDesiredState
        }
        try validateMutationPolicy(state)
        return state
    }

    private func validateShape(_ state: MemoryDesiredState) throws {
        guard state.schemaVersion == MemoryDesiredState.currentSchemaVersion else {
            throw MemoryDesiredStateStoreError.unsupportedSchema(state.schemaVersion)
        }
        guard !state.sessionIdentifier.isEmpty,
              state.sessionIdentifier.count <= 128,
              state.requestingUID > 0,
              state.families.count <= Self.maximumFamilyCount else {
            throw MemoryDesiredStateStoreError.unsafeDesiredState
        }

        var totalProcesses = 0
        var familyIdentifiers: Set<String> = []
        for family in state.families {
            guard !family.identifier.isEmpty,
                  family.identifier.count <= 1024,
                  !family.displayName.isEmpty,
                  family.displayName.count <= 256,
                  !family.bundlePath.isEmpty,
                  family.bundlePath.count <= 4096,
                  !familyIdentifiers.contains(family.identifier) else {
                throw MemoryDesiredStateStoreError.unsafeDesiredState
            }
            familyIdentifiers.insert(family.identifier)
            totalProcesses += family.processes.count
            guard totalProcesses <= Self.maximumProcessCount else {
                throw MemoryDesiredStateStoreError.unsafeDesiredState
            }
            for process in family.processes {
                guard process.familyIdentifier == family.identifier,
                      process.identity.pid > 0,
                      process.identity.effectiveUID == state.requestingUID,
                      process.requestedNiceValue == 5 else {
                    throw MemoryDesiredStateStoreError.unsafeDesiredState
                }
            }
        }
    }

    private func validateMutationPolicy(_ state: MemoryDesiredState) throws {
        if state.shouldStopAndRestore {
            guard state.families.isEmpty else {
                throw MemoryDesiredStateStoreError.unsafeDesiredState
            }
            return
        }

        for family in state.families {
            let canonicalBundle = URL(fileURLWithPath: family.bundlePath)
                .standardizedFileURL.path.lowercased()
            guard canonicalBundle == family.identifier,
                  canonicalBundle.hasPrefix("/applications/") || canonicalBundle.hasPrefix("/users/") else {
                throw MemoryDesiredStateStoreError.unsafeDesiredState
            }
            if canonicalBundle.hasPrefix("/system/") || canonicalBundle.contains("/catalinaperformance.app") {
                throw MemoryDesiredStateStoreError.unsafeDesiredState
            }
            for process in family.processes {
                let executable = URL(fileURLWithPath: process.identity.executablePath)
                    .standardizedFileURL.path.lowercased()
                guard executable.hasPrefix(canonicalBundle + "/contents/") else {
                    throw MemoryDesiredStateStoreError.unsafeDesiredState
                }
            }
        }
    }

    private func prepareDirectory() throws {
        try rejectSymbolicLinkIfPresent(at: directoryURL)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }
        try rejectSymbolicLink(at: directoryURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directoryURL.path
        )
    }

    private func writeAtomically(_ data: Data, to destination: URL, permissions: Int) throws {
        let temporary = directoryURL.appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
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

    private func rejectSymbolicLinkIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) || isSymbolicLink(at: url) else { return }
        try rejectSymbolicLink(at: url)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        if isSymbolicLink(at: url) {
            throw MemoryDesiredStateStoreError.symbolicLinkRejected
        }
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            return values.isSymbolicLink == true
        } catch {
            return false
        }
    }
}
