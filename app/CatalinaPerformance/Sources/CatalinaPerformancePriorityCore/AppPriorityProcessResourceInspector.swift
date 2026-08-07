import Foundation
import CatalinaProcessSupport

public protocol AppPriorityProcessResourceInspecting {
    func residentBytes(pid: Int32) throws -> UInt64
}

extension DarwinAppPriorityProcessInspector: AppPriorityProcessResourceInspecting {
    public func residentBytes(pid: Int32) throws -> UInt64 {
        var resources = CPProcessResourceInfo()
        let result = cp_read_process_resources(pid, &resources)
        guard result == 0 else {
            throw AppPriorityProcessError.resourceReadFailed(pid: pid, code: result)
        }
        guard resources.pid == pid else {
            throw AppPriorityProcessError.invalidProcessData(pid: pid)
        }
        return UInt64(resources.residentBytes)
    }
}
