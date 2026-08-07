import Foundation

public struct MemoryAgentConfirmedManagementSummary: Equatable {
    public let managedFamilyNames: [String]
    public let managedProcessCount: Int

    public init(managedFamilyNames: [String], managedProcessCount: Int) {
        self.managedFamilyNames = managedFamilyNames
        self.managedProcessCount = managedProcessCount
    }

    public var managedFamilyCount: Int {
        return managedFamilyNames.count
    }
}

public extension MemoryAgentRuntimeState {
    var confirmedManagementSummary: MemoryAgentConfirmedManagementSummary {
        var familyNames: [String] = []
        var processCount = 0

        for family in managedFamilies {
            let confirmedProcesses = family.processes.filter { process in
                process.didChangePriority && process.restorationState == .changed
            }
            guard !confirmedProcesses.isEmpty else { continue }
            familyNames.append(family.displayName)
            processCount += confirmedProcesses.count
        }

        return MemoryAgentConfirmedManagementSummary(
            managedFamilyNames: familyNames,
            managedProcessCount: processCount
        )
    }
}
