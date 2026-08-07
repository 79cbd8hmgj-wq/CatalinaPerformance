import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum BackgroundServiceStateStoreError: Error, Equatable {
    case symbolicLinkRejected
    case fileTooLarge
    case corruptState
    case unsupportedSchema(Int)
    case outstandingRestoration
}

public protocol BackgroundServiceStateStoring {
    func loadActive() throws -> BackgroundServiceSessionRecord?
    func saveActive(_ record: BackgroundServiceSessionRecord) throws
    func complete(_ record: BackgroundServiceSessionRecord) throws
    func removeActiveIfResolved() throws
}

public final class BackgroundServiceStateStore: BackgroundServiceStateStoring {
    public static let maximumFileSize = 1_048_576

    public let directoryURL: URL
    public let activeSessionURL: URL
    public let completedSessionURL: URL

    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.activeSessionURL = directoryURL.appendingPathComponent("active-session.json")
        self.completedSessionURL = directoryURL.appendingPathComponent("last-completed-session.json")
        self.fileManager = fileManager
    }

    public func loadActive() throws -> BackgroundServiceSessionRecord? {
        return try loadRecord(at: activeSessionURL, backupCorruptActive: true)
    }

    public func loadCompleted() throws -> BackgroundServiceSessionRecord? {
        return try loadRecord(at: completedSessionURL, backupCorruptActive: false)
    }

    public func saveActive(_ record: BackgroundServiceSessionRecord) throws {
        try validateSchema(record)
        try write(record, to: activeSessionURL)
    }

    public func complete(_ record: BackgroundServiceSessionRecord) throws {
        try validateSchema(record)
        try write(record, to: completedSessionURL)
        if record.hasOutstandingRestoration {
            throw BackgroundServiceStateStoreError.outstandingRestoration
        }
        if fileManager.fileExists(atPath: activeSessionURL.path) {
            try rejectSymbolicLink(at: activeSessionURL)
            try fileManager.removeItem(at: activeSessionURL)
        }
    }

    public func removeActiveIfResolved() throws {
        guard let record = try loadActive() else { return }
        if record.hasOutstandingRestoration {
            throw BackgroundServiceStateStoreError.outstandingRestoration
        }
        try fileManager.removeItem(at: activeSessionURL)
    }

    private func loadRecord(at url: URL, backupCorruptActive: Bool) throws -> BackgroundServiceSessionRecord? {
        try rejectSymbolicLinkIfPresent(at: directoryURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try rejectSymbolicLink(at: url)

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > Self.maximumFileSize {
            throw BackgroundServiceStateStoreError.fileTooLarge
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let record = try decoder.decode(BackgroundServiceSessionRecord.self, from: data)
            try validateSchema(record)
            return record
        } catch let error as BackgroundServiceStateStoreError {
            throw error
        } catch {
            if backupCorruptActive {
                try backupCorruptActiveState()
            }
            throw BackgroundServiceStateStoreError.corruptState
        }
    }

    private func validateSchema(_ record: BackgroundServiceSessionRecord) throws {
        guard record.schemaVersion == BackgroundServiceSessionRecord.currentSchemaVersion else {
            throw BackgroundServiceStateStoreError.unsupportedSchema(record.schemaVersion)
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

    private func write(_ record: BackgroundServiceSessionRecord, to destination: URL) throws {
        try prepareDirectory()
        try rejectSymbolicLinkIfPresent(at: destination)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumFileSize else {
            throw BackgroundServiceStateStoreError.fileTooLarge
        }

        let temporary = directoryURL.appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: [])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
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
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func backupCorruptActiveState() throws {
        guard fileManager.fileExists(atPath: activeSessionURL.path) else { return }
        try prepareDirectory()
        try rejectSymbolicLink(at: activeSessionURL)

        let timestamp = Int(Date().timeIntervalSince1970)
        let backup = directoryURL.appendingPathComponent("active-session.corrupt-\(timestamp).json")
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
        try fileManager.moveItem(at: activeSessionURL, to: backup)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: backup.path
        )

        let backups = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix("active-session.corrupt-") &&
            $0.pathExtension == "json"
        }.sorted { first, second in
            let firstDate = (try? first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let secondDate = (try? second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return firstDate > secondDate
        }

        for oldBackup in backups.dropFirst() {
            try? fileManager.removeItem(at: oldBackup)
        }
    }

    private func rejectSymbolicLinkIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) || isSymbolicLink(at: url) else { return }
        try rejectSymbolicLink(at: url)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        if isSymbolicLink(at: url) {
            throw BackgroundServiceStateStoreError.symbolicLinkRejected
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
