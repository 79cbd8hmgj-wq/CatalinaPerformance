import Foundation
import CatalinaPerformancePriorityCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum MemoryInterventionError: Error, Equatable, CustomStringConvertible {
    case invalidDesiredState
    case sessionConflict
    case identityMismatch
    case protectedProcess
    case statePersistenceFailed
    case priorityVerificationFailed(pid: Int32, expected: Int32, actual: Int32)

    public var description: String {
        switch self {
        case .invalidDesiredState: return "Memory desired state is invalid."
        case .sessionConflict: return "Outstanding memory restoration belongs to another session."
        case .identityMismatch: return "Process identity changed before memory policy mutation."
        case .protectedProcess: return "Protected process was refused by memory management."
        case .statePersistenceFailed: return "Memory restoration state could not be persisted before mutation."
        case .priorityVerificationFailed(let pid, let expected, let actual):
            return "Priority verification failed for PID \(pid): expected \(expected), got \(actual)."
        }
    }
}

public struct MemoryInterventionOutcome: Equatable {
    public let managedFamilyCount: Int
    public let managedProcessCount: Int
    public let outstandingRestorationCount: Int
    public let failures: [String]

    public init(
        managedFamilyCount: Int,
        managedProcessCount: Int,
        outstandingRestorationCount: Int,
        failures: [String]
    ) {
        self.managedFamilyCount = managedFamilyCount
        self.managedProcessCount = managedProcessCount
        self.outstandingRestorationCount = outstandingRestorationCount
        self.failures = failures
    }
}

public final class MemoryInterventionController {
    private static let targetNiceValue: Int32 = 5
    private static let protectedProcessNames: Set<String> = [
        "launchd",
        "kernel_task",
        "windowserver",
        "loginwindow",
        "systemuiserver",
        "finder",
        "dock",
        "catalinaperformance",
        "catalinaperformancepriorityagent",
        "catalinaperformancememoryagent"
    ]

    private let inspector: AppPriorityProcessInspecting
    private let mutator: AppPriorityPriorityMutating
    private let stateStore: MemoryAgentStateStoring
    private let requestingUID: UInt32
    private let nowProvider: () -> Date

    public init(
        inspector: AppPriorityProcessInspecting,
        mutator: AppPriorityPriorityMutating,
        stateStore: MemoryAgentStateStoring,
        requestingUID: UInt32,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.inspector = inspector
        self.mutator = mutator
        self.stateStore = stateStore
        self.requestingUID = requestingUID
        self.nowProvider = nowProvider
    }

    public func reconcile(desired: MemoryDesiredState) throws -> MemoryInterventionOutcome {
        try validateDesiredState(desired)
        var state = try stateForDesired(desired)
        var failures: [String] = []

        if desired.shouldStopAndRestore {
            let outcome = try restoreAll(state: &state)
            state.lastAppliedGeneration = desired.generation
            try stateStore.writeRuntimeState(state)
            stateStore.removeRuntimeFilesAfterSuccessfulRestore()
            return outcome
        }

        let desiredIDs = Set(desired.families.map { $0.identifier })

        // Restore families that are no longer desired before admitting replacements.
        for index in state.managedFamilies.indices.reversed() {
            if !desiredIDs.contains(state.managedFamilies[index].identifier) {
                restoreFamily(at: index, state: &state, failures: &failures)
            }
        }
        state.managedFamilies.removeAll { family in
            !desiredIDs.contains(family.identifier) && !family.hasOutstandingRestoration
        }

        for desiredFamily in desired.families {
            reconcileFamily(desiredFamily, state: &state, failures: &failures)
        }

        state.lastAppliedGeneration = desired.generation
        try stateStore.writeRuntimeState(state)
        return outcome(from: state, failures: failures)
    }

    public func restoreAll() throws -> MemoryInterventionOutcome {
        guard var state = stateStore.runtimeStateIfPresent() else {
            return MemoryInterventionOutcome(
                managedFamilyCount: 0,
                managedProcessCount: 0,
                outstandingRestorationCount: 0,
                failures: []
            )
        }
        let outcome = try restoreAll(state: &state)
        stateStore.removeRuntimeFilesAfterSuccessfulRestore()
        return outcome
    }

    private func validateDesiredState(_ desired: MemoryDesiredState) throws {
        guard desired.schemaVersion == MemoryDesiredState.currentSchemaVersion,
              desired.requestingUID == requestingUID,
              requestingUID > 0,
              desired.families.count <= 3 else {
            throw MemoryInterventionError.invalidDesiredState
        }
        if desired.shouldStopAndRestore && !desired.families.isEmpty {
            throw MemoryInterventionError.invalidDesiredState
        }
        for family in desired.families {
            guard !family.identifier.isEmpty else {
                throw MemoryInterventionError.invalidDesiredState
            }
            for process in family.processes {
                guard process.familyIdentifier == family.identifier,
                      process.requestedNiceValue == Self.targetNiceValue,
                      process.identity.effectiveUID == requestingUID,
                      process.identity.effectiveUID != 0 else {
                    throw MemoryInterventionError.invalidDesiredState
                }
            }
        }
    }

    private func stateForDesired(_ desired: MemoryDesiredState) throws -> MemoryAgentRuntimeState {
        if let existing = stateStore.runtimeStateIfPresent() {
            if existing.sessionIdentifier != desired.sessionIdentifier && existing.hasOutstandingRestoration {
                throw MemoryInterventionError.sessionConflict
            }
            if existing.sessionIdentifier == desired.sessionIdentifier {
                return existing
            }
        }

        let fresh = MemoryAgentRuntimeState(
            sessionIdentifier: desired.sessionIdentifier,
            requestingUID: requestingUID,
            startedAt: nowProvider(),
            lastAppliedGeneration: 0,
            monitorIdentity: stateStore.loadMonitorIdentity(),
            managedFamilies: []
        )
        try stateStore.writeRuntimeState(fresh)
        return fresh
    }

    private func reconcileFamily(
        _ desiredFamily: MemoryDesiredFamily,
        state: inout MemoryAgentRuntimeState,
        failures: inout [String]
    ) {
        var familyIndex = state.managedFamilies.firstIndex { $0.identifier == desiredFamily.identifier }
        if familyIndex == nil {
            state.managedFamilies.append(MemoryManagedFamilyRecord(
                identifier: desiredFamily.identifier,
                displayName: desiredFamily.displayName,
                bundlePath: desiredFamily.bundlePath,
                processes: []
            ))
            familyIndex = state.managedFamilies.count - 1
        }
        guard let resolvedFamilyIndex = familyIndex else { return }

        let desiredProcessKeys = Set(desiredFamily.processes.map { processKey($0.identity) })
        for processIndex in state.managedFamilies[resolvedFamilyIndex].processes.indices.reversed() {
            let record = state.managedFamilies[resolvedFamilyIndex].processes[processIndex]
            if !desiredProcessKeys.contains(processKey(record.identity)) {
                restoreProcess(
                    familyIndex: resolvedFamilyIndex,
                    processIndex: processIndex,
                    state: &state,
                    failures: &failures
                )
            }
        }
        state.managedFamilies[resolvedFamilyIndex].processes.removeAll { record in
            !desiredProcessKeys.contains(processKey(record.identity)) && !record.requiresRestoration
        }

        let existingKeys = Set(state.managedFamilies[resolvedFamilyIndex].processes.map { processKey($0.identity) })
        for desiredProcess in desiredFamily.processes where !existingKeys.contains(processKey(desiredProcess.identity)) {
            do {
                try applyProcess(
                    desiredProcess,
                    familyIndex: resolvedFamilyIndex,
                    state: &state
                )
            } catch {
                failures.append(String(describing: error))
            }
        }
    }

    private func applyProcess(
        _ desiredProcess: MemoryDesiredProcess,
        familyIndex: Int,
        state: inout MemoryAgentRuntimeState
    ) throws {
        let current = try inspector.process(pid: desiredProcess.identity.pid)
        guard desiredProcess.identity.matchesForMutation(current) else {
            throw MemoryInterventionError.identityMismatch
        }
        try validateProcessForMutation(current)

        let original = try mutator.priority(pid: current.pid)
        let shouldChange = original < Self.targetNiceValue
        let applied = shouldChange ? Self.targetNiceValue : original
        let record = MemoryManagedProcessRecord(
            identity: current,
            familyIdentifier: desiredProcess.familyIdentifier,
            originalNiceValue: original,
            appliedNiceValue: applied,
            didChangePriority: shouldChange,
            restorationState: shouldChange ? .changed : .unchanged,
            errorMessage: nil
        )

        state.managedFamilies[familyIndex].processes.append(record)
        do {
            try stateStore.writeRuntimeState(state)
        } catch {
            state.managedFamilies[familyIndex].processes.removeLast()
            throw MemoryInterventionError.statePersistenceFailed
        }

        guard shouldChange else { return }

        do {
            try mutator.setPriority(pid: current.pid, value: Self.targetNiceValue)
            let verified = try mutator.priority(pid: current.pid)
            guard verified == Self.targetNiceValue else {
                throw MemoryInterventionError.priorityVerificationFailed(
                    pid: current.pid,
                    expected: Self.targetNiceValue,
                    actual: verified
                )
            }
        } catch {
            if let processIndex = state.managedFamilies[familyIndex].processes.firstIndex(where: {
                processKey($0.identity) == processKey(current)
            }) {
                state.managedFamilies[familyIndex].processes[processIndex].restorationState = .failed
                state.managedFamilies[familyIndex].processes[processIndex].errorMessage = String(describing: error)
                try? stateStore.writeRuntimeState(state)
            }
            throw error
        }
    }

    private func restoreAll(state: inout MemoryAgentRuntimeState) throws -> MemoryInterventionOutcome {
        var failures: [String] = []
        for familyIndex in state.managedFamilies.indices.reversed() {
            restoreFamily(at: familyIndex, state: &state, failures: &failures)
        }
        state.managedFamilies.removeAll { !$0.hasOutstandingRestoration }
        try stateStore.writeRuntimeState(state)
        return outcome(from: state, failures: failures)
    }

    private func restoreFamily(
        at familyIndex: Int,
        state: inout MemoryAgentRuntimeState,
        failures: inout [String]
    ) {
        guard state.managedFamilies.indices.contains(familyIndex) else { return }
        for processIndex in state.managedFamilies[familyIndex].processes.indices.reversed() {
            restoreProcess(
                familyIndex: familyIndex,
                processIndex: processIndex,
                state: &state,
                failures: &failures
            )
        }
    }

    private func restoreProcess(
        familyIndex: Int,
        processIndex: Int,
        state: inout MemoryAgentRuntimeState,
        failures: inout [String]
    ) {
        guard state.managedFamilies.indices.contains(familyIndex),
              state.managedFamilies[familyIndex].processes.indices.contains(processIndex) else {
            return
        }

        var record = state.managedFamilies[familyIndex].processes[processIndex]
        guard record.didChangePriority else {
            record.restorationState = .restored
            record.errorMessage = nil
            state.managedFamilies[familyIndex].processes[processIndex] = record
            try? stateStore.writeRuntimeState(state)
            return
        }

        do {
            let current = try inspector.process(pid: record.identity.pid)
            guard record.identity.matchesForMutation(current) else {
                record.restorationState = .mismatched
                record.errorMessage = "PID identity changed; restoration was refused."
                state.managedFamilies[familyIndex].processes[processIndex] = record
                try stateStore.writeRuntimeState(state)
                failures.append(record.errorMessage ?? "Identity mismatch")
                return
            }
            try validateProcessForMutation(current)

            let currentNice = try mutator.priority(pid: current.pid)
            guard currentNice == record.appliedNiceValue else {
                record.restorationState = .mismatched
                record.errorMessage = "Priority changed externally; CatalinaPerformance preserved the external value."
                state.managedFamilies[familyIndex].processes[processIndex] = record
                try stateStore.writeRuntimeState(state)
                failures.append(record.errorMessage ?? "Priority changed externally")
                return
            }

            try mutator.setPriority(pid: current.pid, value: record.originalNiceValue)
            let verified = try mutator.priority(pid: current.pid)
            guard verified == record.originalNiceValue else {
                throw MemoryInterventionError.priorityVerificationFailed(
                    pid: current.pid,
                    expected: record.originalNiceValue,
                    actual: verified
                )
            }

            record.restorationState = .restored
            record.errorMessage = nil
            state.managedFamilies[familyIndex].processes[processIndex] = record
            try stateStore.writeRuntimeState(state)
        } catch {
            if isProcessGone(error) {
                record.restorationState = .exited
                record.errorMessage = nil
            } else {
                record.restorationState = .failed
                record.errorMessage = String(describing: error)
                failures.append(String(describing: error))
            }
            state.managedFamilies[familyIndex].processes[processIndex] = record
            try? stateStore.writeRuntimeState(state)
        }
    }

    private func validateProcessForMutation(_ identity: AppPriorityProcessIdentity) throws {
        guard identity.effectiveUID == requestingUID,
              identity.effectiveUID != 0,
              !Self.protectedProcessNames.contains(identity.processName.lowercased()) else {
            throw MemoryInterventionError.protectedProcess
        }
        let path = identity.executablePath.lowercased()
        guard !path.hasPrefix("/system/"),
              !path.hasPrefix("/usr/"),
              !path.hasPrefix("/bin/"),
              !path.hasPrefix("/sbin/"),
              !path.hasPrefix("/private/"),
              !path.contains("/catalinaperformance.app/") else {
            throw MemoryInterventionError.protectedProcess
        }
    }

    private func processKey(_ identity: AppPriorityProcessIdentity) -> String {
        return "\(identity.pid)|\(identity.effectiveUID)|\(identity.startSeconds)|\(identity.startMicroseconds)|\(identity.executablePath)"
    }

    private func isProcessGone(_ error: Error) -> Bool {
        guard case AppPriorityProcessError.readFailed(_, let code) = error else { return false }
        return code == -Int32(ESRCH)
    }

    private func outcome(
        from state: MemoryAgentRuntimeState,
        failures: [String]
    ) -> MemoryInterventionOutcome {
        let processes = state.managedFamilies.reduce(0) { $0 + $1.processes.count }
        let outstanding = state.managedFamilies.reduce(0) { partial, family in
            partial + family.processes.filter { $0.requiresRestoration }.count
        }
        return MemoryInterventionOutcome(
            managedFamilyCount: state.managedFamilies.count,
            managedProcessCount: processes,
            outstandingRestorationCount: outstanding,
            failures: failures
        )
    }
}
