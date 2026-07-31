import Foundation
import CatalinaProcessSupport

public enum AppPriorityProcessError: Error, Equatable, CustomStringConvertible {
    case unsupported
    case listFailed(Int32)
    case readFailed(pid: Int32, code: Int32)
    case priorityReadFailed(pid: Int32, code: Int32)
    case priorityWriteFailed(pid: Int32, code: Int32)
    case invalidProcessData(pid: Int32)

    public var description: String {
        switch self {
        case .unsupported: return "Process priority support is unavailable on this platform."
        case .listFailed(let code): return "Unable to list processes (\(code))."
        case .readFailed(let pid, let code): return "Unable to read process \(pid) (\(code))."
        case .priorityReadFailed(let pid, let code): return "Unable to read priority for process \(pid) (\(code))."
        case .priorityWriteFailed(let pid, let code): return "Unable to set priority for process \(pid) (\(code))."
        case .invalidProcessData(let pid): return "Process \(pid) returned invalid identity data."
        }
    }
}

public struct AppPriorityProcessIdentity: Codable, Hashable {
    public let pid: Int32
    public let parentPID: Int32
    public let effectiveUID: UInt32
    public let executablePath: String
    public let startSeconds: Int64
    public let startMicroseconds: Int32
    public let processName: String
    public let niceValue: Int32

    public init(pid: Int32, parentPID: Int32, effectiveUID: UInt32, executablePath: String, startSeconds: Int64, startMicroseconds: Int32, processName: String, niceValue: Int32) {
        self.pid = pid
        self.parentPID = parentPID
        self.effectiveUID = effectiveUID
        self.executablePath = executablePath
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.processName = processName
        self.niceValue = niceValue
    }

    public func matchesForMutation(_ current: AppPriorityProcessIdentity) -> Bool {
        return pid == current.pid &&
            effectiveUID == current.effectiveUID &&
            executablePath == current.executablePath &&
            startSeconds == current.startSeconds &&
            startMicroseconds == current.startMicroseconds
    }
}

public protocol AppPriorityProcessInspecting {
    func allProcesses() throws -> [AppPriorityProcessIdentity]
    func process(pid: Int32) throws -> AppPriorityProcessIdentity
}

public protocol AppPriorityPriorityMutating {
    func priority(pid: Int32) throws -> Int32
    func setPriority(pid: Int32, value: Int32) throws
}

public final class DarwinAppPriorityProcessInspector: AppPriorityProcessInspecting, AppPriorityPriorityMutating {
    public init() {}

    public func allProcesses() throws -> [AppPriorityProcessIdentity] {
        guard cp_process_support_available() != 0 else { throw AppPriorityProcessError.unsupported }
        let required = cp_list_processes(nil, 0)
        guard required >= 0 else { throw AppPriorityProcessError.listFailed(required) }
        if required == 0 { return [] }
        var buffer = Array(repeating: CPProcessInfo(), count: Int(required) + 128)
        let written = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            return cp_list_processes(pointer.baseAddress, Int32(pointer.count))
        }
        guard written >= 0 else { throw AppPriorityProcessError.listFailed(written) }
        return try buffer.prefix(Int(written)).map { try identity(from: $0) }
    }

    public func process(pid: Int32) throws -> AppPriorityProcessIdentity {
        guard cp_process_support_available() != 0 else { throw AppPriorityProcessError.unsupported }
        var info = CPProcessInfo()
        let result = cp_read_process(pid, &info)
        guard result == 0 else { throw AppPriorityProcessError.readFailed(pid: pid, code: result) }
        return try identity(from: info)
    }

    public func priority(pid: Int32) throws -> Int32 {
        var value: Int32 = 0
        let result = cp_get_process_priority(pid, &value)
        guard result == 0 else { throw AppPriorityProcessError.priorityReadFailed(pid: pid, code: result) }
        return value
    }

    public func setPriority(pid: Int32, value: Int32) throws {
        let result = cp_set_process_priority(pid, value)
        guard result == 0 else { throw AppPriorityProcessError.priorityWriteFailed(pid: pid, code: result) }
    }

    private func identity(from info: CPProcessInfo) throws -> AppPriorityProcessIdentity {
        let rawPath = stringFromTuple(info.executablePath, declaredLength: info.pathLength)
        let name = stringFromTuple(info.name, declaredLength: info.nameLength)
        guard info.pid > 0, !rawPath.isEmpty, info.pathLength > 0 else {
            throw AppPriorityProcessError.invalidProcessData(pid: info.pid)
        }
        let canonicalPath = URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard !canonicalPath.isEmpty else { throw AppPriorityProcessError.invalidProcessData(pid: info.pid) }
        return AppPriorityProcessIdentity(
            pid: info.pid,
            parentPID: info.parentPid,
            effectiveUID: UInt32(info.effectiveUid),
            executablePath: canonicalPath,
            startSeconds: info.startSeconds,
            startMicroseconds: info.startMicroseconds,
            processName: name,
            niceValue: info.niceValue
        )
    }

    private func stringFromTuple<T>(_ tuple: T, declaredLength: Int32) -> String {
        guard declaredLength > 0 else { return "" }
        var mutableTuple = tuple
        return withUnsafePointer(to: &mutableTuple) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(declaredLength) + 1) { chars in
                String(cString: chars)
            }
        }
    }
}
