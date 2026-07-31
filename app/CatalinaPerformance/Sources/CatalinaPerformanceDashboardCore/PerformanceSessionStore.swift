import Foundation
import CatalinaProcessSupport
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum PerformanceSessionStoreLoadResult<Value> {
    case missing
    case loaded(Value)
    case recoveredInvalid(backupURL: URL, message: String)
}

public protocol PerformanceSessionStoring {
    func loadActive() -> PerformanceSessionStoreLoadResult<PerformanceSessionRecord>
    func saveActive(_ record: PerformanceSessionRecord) throws
    func removeActive() throws
    func loadCompleted() -> PerformanceSessionStoreLoadResult<CompletedPerformanceSessionReport>
    func saveCompleted(_ report: CompletedPerformanceSessionReport) throws
}

public enum PerformanceSessionStoreError: Error, CustomStringConvertible {
    case unsafePath(String)
    case invalidDirectory(String)
    case invalidSchema(Int)
    case oversized(Int)
    case atomicWriteFailed(Int32)

    public var description: String {
        switch self {
        case .unsafePath(let path): return "Unsafe dashboard path: \(path)"
        case .invalidDirectory(let path): return "Invalid dashboard directory: \(path)"
        case .invalidSchema(let version): return "Unsupported dashboard schema version \(version)."
        case .oversized(let size): return "Dashboard JSON exceeds the 1048576-byte limit (\(size))."
        case .atomicWriteFailed(let code): return "Atomic dashboard write failed (\(code))."
        }
    }
}

public final class PerformanceSessionStore: PerformanceSessionStoring {
    public static let maximumFileSize = 1_048_576
    public static let maximumInvalidBackups = 3

    private let directoryURL: URL
    private let activeURL: URL
    private let completedURL: URL
    private let fileManager: FileManager
    private let currentUID: UInt32
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        currentUID: UInt32 = UInt32(getuid())
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.activeURL = self.directoryURL.appendingPathComponent("active-session.json")
        self.completedURL = self.directoryURL.appendingPathComponent("last-completed-session.json")
        self.fileManager = fileManager
        self.currentUID = currentUID
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func loadActive() -> PerformanceSessionStoreLoadResult<PerformanceSessionRecord> {
        load(PerformanceSessionRecord.self, from: activeURL, prefix: "active-session") { $0.schemaVersion }
    }

    public func saveActive(_ record: PerformanceSessionRecord) throws {
        guard record.schemaVersion == 1 else { throw PerformanceSessionStoreError.invalidSchema(record.schemaVersion) }
        try save(record, to: activeURL)
    }

    public func removeActive() throws {
        try ensureDirectory(createIfMissing: false)
        guard fileManager.fileExists(atPath: activeURL.path) else { return }
        try ensureSafeExistingFile(activeURL)
        try fileManager.removeItem(at: activeURL)
    }

    public func loadCompleted() -> PerformanceSessionStoreLoadResult<CompletedPerformanceSessionReport> {
        load(CompletedPerformanceSessionReport.self, from: completedURL, prefix: "last-completed-session") { $0.schemaVersion }
    }

    public func saveCompleted(_ report: CompletedPerformanceSessionReport) throws {
        guard report.schemaVersion == 1 else { throw PerformanceSessionStoreError.invalidSchema(report.schemaVersion) }
        try save(report, to: completedURL)
    }

    private func load<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        prefix: String,
        schema: (Value) -> Int
    ) -> PerformanceSessionStoreLoadResult<Value> {
        do {
            try ensureDirectory(createIfMissing: false)
            guard fileManager.fileExists(atPath: url.path) else { return .missing }
            try ensureSafeExistingFile(url)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= Self.maximumFileSize else { throw PerformanceSessionStoreError.oversized(size) }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let value = try decoder.decode(Value.self, from: data)
            guard schema(value) == 1 else { throw PerformanceSessionStoreError.invalidSchema(schema(value)) }
            return .loaded(value)
        } catch {
            guard fileManager.fileExists(atPath: url.path) else {
                return .recoveredInvalid(backupURL: url, message: String(describing: error))
            }
            let backup = invalidBackupURL(prefix: prefix)
            do {
                try movePathWithoutFollowingSource(from: url, to: backup)
                pruneBackups(prefix: prefix)
                return .recoveredInvalid(backupURL: backup, message: String(describing: error))
            } catch let moveError {
                return .recoveredInvalid(backupURL: url, message: "\(error); invalid file could not be moved: \(moveError)")
            }
        }
    }

    private func save<Value: Codable>(_ value: Value, to destination: URL) throws {
        try ensureDirectory(createIfMissing: true)
        if fileManager.fileExists(atPath: destination.path) {
            try ensureSafeExistingFile(destination)
        }
        let temporary = directoryURL.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        if fileManager.fileExists(atPath: temporary.path) { try ensureSafeExistingFile(temporary) }
        defer { try? fileManager.removeItem(at: temporary) }

        let data = try encoder.encode(value)
        guard data.count <= Self.maximumFileSize else { throw PerformanceSessionStoreError.oversized(data.count) }
        try data.write(to: temporary, options: [])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: temporary.path)
        _ = try decoder.decode(Value.self, from: Data(contentsOf: temporary))

        let result = temporary.path.withCString { source in
            destination.path.withCString { target in rename(source, target) }
        }
        guard result == 0 else { throw PerformanceSessionStoreError.atomicWriteFailed(Int32(errno)) }
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: destination.path)
    }

    private func ensureDirectory(createIfMissing: Bool) throws {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        if !exists {
            guard createIfMissing else { return }
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [
                .posixPermissions: NSNumber(value: Int16(0o700))
            ])
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: directoryURL.path)
        }
        var info = CPFileInfo()
        let result = directoryURL.path.withCString { cp_lstat_path($0, &info) }
        guard result == 0,
              info.isDirectory == 1,
              info.isSymbolicLink == 0,
              UInt32(info.ownerUid) == currentUID,
              (info.mode & 0o022) == 0 else {
            throw PerformanceSessionStoreError.invalidDirectory(directoryURL.path)
        }
    }

    private func ensureSafeExistingFile(_ url: URL) throws {
        var info = CPFileInfo()
        let result = url.path.withCString { cp_lstat_path($0, &info) }
        guard result == 0,
              info.isRegularFile == 1,
              info.isSymbolicLink == 0,
              UInt32(info.ownerUid) == currentUID,
              (info.mode & 0o022) == 0 else {
            throw PerformanceSessionStoreError.unsafePath(url.path)
        }
    }

    private func invalidBackupURL(prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directoryURL.appendingPathComponent("\(prefix).invalid-\(formatter.string(from: Date()))-\(UUID().uuidString).json")
    }

    private func movePathWithoutFollowingSource(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in rename(sourcePath, destinationPath) }
        }
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: source.path])
        }
    }

    private func pruneBackups(prefix: String) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        let matching = names.filter { $0.hasPrefix("\(prefix).invalid-") && $0.hasSuffix(".json") }.sorted()
        guard matching.count > Self.maximumInvalidBackups else { return }
        for name in matching.prefix(matching.count - Self.maximumInvalidBackups) {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
        }
    }
}
