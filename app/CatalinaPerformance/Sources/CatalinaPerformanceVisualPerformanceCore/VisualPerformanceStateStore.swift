import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum VisualPerformanceStateStoreError: Error, Equatable {
    case unsupportedOrMalformedState
    case symbolicLinkRejected
    case fileTooLarge
}

public protocol VisualPerformanceStateStoring {
    func loadActive() throws -> VisualPerformanceSessionRecord?
    func loadLastCompleted() throws -> VisualPerformanceSessionRecord?
    func writeActive(_ record: VisualPerformanceSessionRecord) throws
    func complete(_ record: VisualPerformanceSessionRecord) throws
    func removeActive() throws
}

public final class VisualPerformanceStateStore: VisualPerformanceStateStoring {
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

    public func loadActive() throws -> VisualPerformanceSessionRecord? {
        return try loadRecord(at: activeSessionURL)
    }

    public func loadLastCompleted() throws -> VisualPerformanceSessionRecord? {
        return try loadRecord(at: completedSessionURL)
    }

    public func writeActive(_ record: VisualPerformanceSessionRecord) throws {
        try validate(record)
        try write(record, to: activeSessionURL)
    }

    public func complete(_ record: VisualPerformanceSessionRecord) throws {
        try validate(record)
        try write(record, to: completedSessionURL)
        try removeActive()
    }

    public func removeActive() throws {
        guard pathExistsIncludingSymbolicLink(activeSessionURL.path) else { return }
        try rejectSymbolicLink(at: activeSessionURL)
        try fileManager.removeItem(at: activeSessionURL)
    }

    private func loadRecord(at url: URL) throws -> VisualPerformanceSessionRecord? {
        try rejectSymbolicLinkIfPresent(at: directoryURL)
        guard pathExistsIncludingSymbolicLink(url.path) else { return nil }
        try rejectSymbolicLink(at: url)

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > Self.maximumFileSize {
            throw VisualPerformanceStateStoreError.fileTooLarge
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let record = try decode(data)
            try validate(record)
            return record
        } catch let error as VisualPerformanceStateStoreError {
            throw error
        } catch {
            throw VisualPerformanceStateStoreError.unsupportedOrMalformedState
        }
    }

    private func validate(_ record: VisualPerformanceSessionRecord) throws {
        guard record.schemaVersion == VisualPerformanceSessionRecord.currentSchemaVersion else {
            throw VisualPerformanceStateStoreError.unsupportedOrMalformedState
        }
    }

    private func prepareDirectory() throws {
        try rejectSymbolicLinkIfPresent(at: directoryURL)
        if !pathExistsIncludingSymbolicLink(directoryURL.path) {
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

    private func write(_ record: VisualPerformanceSessionRecord, to destination: URL) throws {
        try prepareDirectory()
        try rejectSymbolicLinkIfPresent(at: destination)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumFileSize else {
            throw VisualPerformanceStateStoreError.fileTooLarge
        }

        let temporary = directoryURL.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            try data.write(to: temporary, options: [])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: temporary.path
            )

            let verificationData = try Data(contentsOf: temporary, options: [.mappedIfSafe])
            let verificationRecord = try decode(verificationData)
            try validate(verificationRecord)
            guard verificationRecord == record else {
                throw VisualPerformanceStateStoreError.unsupportedOrMalformedState
            }

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

    private func decode(_ data: Data) throws -> VisualPerformanceSessionRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(VisualPerformanceSessionRecord.self, from: data)
        } catch {
            throw VisualPerformanceStateStoreError.unsupportedOrMalformedState
        }
    }

    private func rejectSymbolicLinkIfPresent(at url: URL) throws {
        guard pathExistsIncludingSymbolicLink(url.path) else { return }
        try rejectSymbolicLink(at: url)
    }

    private func rejectSymbolicLink(at url: URL) throws {
        var information = stat()
        if lstat(url.path, &information) == 0 && (information.st_mode & S_IFMT) == S_IFLNK {
            throw VisualPerformanceStateStoreError.symbolicLinkRejected
        }
    }

    private func pathExistsIncludingSymbolicLink(_ path: String) -> Bool {
        var information = stat()
        return lstat(path, &information) == 0
    }
}
