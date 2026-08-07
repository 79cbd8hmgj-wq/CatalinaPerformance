import Foundation

public protocol AppPriorityMonitorClock {
    func sleep(seconds: TimeInterval)
}

public struct SystemAppPriorityMonitorClock: AppPriorityMonitorClock {
    public init() {}
    public func sleep(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

public struct AppPriorityScanOutcome: Equatable {
    public let changedRecords: [AppPriorityRestoreRecord]
    public let boostedCount: Int
    public let unchangedCount: Int
    public let skippedCount: Int
    public let mainProcessFound: Bool
    public let trackedProcessCount: Int
    public let focusedFirefox: FocusedFirefoxStatusDetails?

    public init(
        changedRecords: [AppPriorityRestoreRecord],
        boostedCount: Int,
        unchangedCount: Int,
        skippedCount: Int,
        mainProcessFound: Bool,
        trackedProcessCount: Int = 0,
        focusedFirefox: FocusedFirefoxStatusDetails? = nil
    ) {
        self.changedRecords = changedRecords
        self.boostedCount = boostedCount
        self.unchangedCount = unchangedCount
        self.skippedCount = skippedCount
        self.mainProcessFound = mainProcessFound
        self.trackedProcessCount = trackedProcessCount
        self.focusedFirefox = focusedFirefox
    }
}

public struct AppPriorityRestoreOutcome: Equatable {
    public let restoredCount: Int
    public let exitedCount: Int
    public let mismatchedCount: Int
    public let failedCount: Int
    public let outstandingRecords: [AppPriorityRestoreRecord]

    public init(restoredCount: Int, exitedCount: Int, mismatchedCount: Int, failedCount: Int, outstandingRecords: [AppPriorityRestoreRecord]) {
        self.restoredCount = restoredCount
        self.exitedCount = exitedCount
        self.mismatchedCount = mismatchedCount
        self.failedCount = failedCount
        self.outstandingRecords = outstandingRecords
    }
}

private enum AppPrioritySingleRestoreResult {
    case restored
    case exited
    case mismatched(AppPriorityRestoreRecord)
    case failed(AppPriorityRestoreRecord)
}

public final class AppPriorityMonitor {
    public static let targetNiceValue: Int32 = -5

    private let selection: ValidatedAppPrioritySelection
    private let inspector: AppPriorityProcessInspecting
    private let activityInspector: AppPriorityProcessActivityInspecting
    private let mutator: AppPriorityPriorityMutating
    private let stateStore: AppPriorityStateStore
    private let clock: AppPriorityMonitorClock
    private let sessionIdentifier: String
    private let policy: AppPriorityPolicy
    private let contentSelector = FocusedFirefoxContentSelector()
    private var runtimeState: AppPriorityRuntimeState

    public init(
        selection: ValidatedAppPrioritySelection,
        inspector: AppPriorityProcessInspecting,
        activityInspector: AppPriorityProcessActivityInspecting,
        mutator: AppPriorityPriorityMutating,
        stateStore: AppPriorityStateStore,
        clock: AppPriorityMonitorClock = SystemAppPriorityMonitorClock(),
        sessionIdentifier: String = UUID().uuidString,
        monitorIdentity: AppPriorityMonitorIdentity? = nil,
        startedAt: Date = Date()
    ) throws {
        guard selection.enabled, let application = selection.application else {
            throw AppPriorityValidationError.featureEnabledWithoutApplication
        }
        self.selection = selection
        self.inspector = inspector
        self.activityInspector = activityInspector
        self.mutator = mutator
        self.stateStore = stateStore
        self.clock = clock
        self.sessionIdentifier = sessionIdentifier
        self.policy = AppPriorityPolicy.policy(for: application)

        if let existing = stateStore.runtimeStateIfPresent(),
           existing.sessionIdentifier == sessionIdentifier,
           existing.requestingUID == selection.requestingUID,
           existing.selectedApplication == application {
            self.runtimeState = existing
            self.runtimeState.policyKind = policy.kind
            if policy.kind == .focusedFirefox && self.runtimeState.focusedFirefoxState == nil {
                self.runtimeState.focusedFirefoxState = .empty
            }
        } else {
            self.runtimeState = AppPriorityRuntimeState(
                sessionIdentifier: sessionIdentifier,
                selectedApplication: application,
                requestingUID: selection.requestingUID,
                monitorIdentity: monitorIdentity,
                records: [],
                startedAt: startedAt,
                policyKind: policy.kind,
                focusedFirefoxState: policy.kind == .focusedFirefox ? .empty : nil
            )
        }
    }

    public func scanOnce() throws -> AppPriorityScanOutcome {
        guard let application = selection.application else {
            throw AppPriorityValidationError.featureEnabledWithoutApplication
        }
        let snapshot = try inspector.allProcesses()
        switch policy.kind {
        case .focusedFirefox:
            return try scanFocusedFirefox(application: application, snapshot: snapshot)
        case .mainProcessOnly, .verifiedProcessFamily:
            return try scanGeneric(application: application, snapshot: snapshot)
        }
    }

    private func scanGeneric(
        application: AppPriorityApplication,
        snapshot: [AppPriorityProcessIdentity]
    ) throws -> AppPriorityScanOutcome {
        let family = AppPriorityProcessFamilyResolver.resolve(
            application: application,
            requestingUID: selection.requestingUID,
            processes: snapshot,
            policyKind: policy.kind
        )
        var changedRecords: [AppPriorityRestoreRecord] = []
        var unchangedCount = 0
        var skippedCount = family.skipped.count

        for candidate in family.eligible {
            if runtimeState.records.contains(where: {
                $0.identity.matchesForMutation(candidate) && $0.didChangePriority
            }) {
                continue
            }
            do {
                if let record = try ensurePriority(
                    identity: candidate,
                    role: .generic,
                    targetNiceValue: policy.targetNiceValue
                ) {
                    runtimeState.records.append(record)
                    changedRecords.append(record)
                } else {
                    unchangedCount += 1
                }
            } catch {
                skippedCount += 1
            }
        }

        runtimeState.policyKind = policy.kind
        try stateStore.writeRuntimeState(runtimeState)
        return AppPriorityScanOutcome(
            changedRecords: changedRecords,
            boostedCount: actualChangedRecordCount(),
            unchangedCount: unchangedCount,
            skippedCount: skippedCount,
            mainProcessFound: family.mainProcessFound,
            trackedProcessCount: family.eligible.count
        )
    }

    private func scanFocusedFirefox(
        application: AppPriorityApplication,
        snapshot: [AppPriorityProcessIdentity]
    ) throws -> AppPriorityScanOutcome {
        let family = AppPriorityProcessFamilyResolver.resolve(
            application: application,
            requestingUID: selection.requestingUID,
            processes: snapshot,
            policyKind: .focusedFirefox
        )
        var skippedCount = 0
        var argumentsByPID: [Int32: [String]] = [:]
        for identity in family.eligible {
            do {
                let fresh = try inspector.process(pid: identity.pid)
                guard identity.matchesForMutation(fresh) else {
                    skippedCount += 1
                    continue
                }
                argumentsByPID[identity.pid] = try activityInspector.arguments(pid: identity.pid)
            } catch {
                skippedCount += 1
            }
        }

        let classified = FocusedFirefoxProcessClassifier.classify(
            application: application,
            requestingUID: selection.requestingUID,
            processes: snapshot,
            argumentsByPID: argumentsByPID
        )
        skippedCount += classified.skippedCount
        var focusedState = runtimeState.focusedFirefoxState ?? .empty
        var warnings = classified.warnings
        var changedRecords: [AppPriorityRestoreRecord] = []
        var unchangedCount = 0

        let previousParent = focusedState.parentIdentity
        let parentChanged = !identitiesMatch(previousParent, classified.parent)
        if parentChanged {
            let staleContentRecords = runtimeState.records.filter { $0.role == .contentTarget }
            for record in staleContentRecords {
                switch restoreSingleRecord(record) {
                case .restored, .exited:
                    removeRecord(matching: record)
                case .mismatched(let outstanding), .failed(let outstanding):
                    replaceRecord(outstanding)
                    warnings.append("A previous Firefox content target still requires restoration after relaunch.")
                }
            }
            focusedState.contentSelectionState = .empty
            focusedState.contentTargetIdentity = nil
        }

        let parentReconciled = reconcileFocusedRole(
            role: .parentUI,
            desiredIdentity: classified.parent,
            warnings: &warnings
        )
        if parentReconciled, let parent = classified.parent {
            do {
                if let record = try ensureFocusedPriority(identity: parent, role: .parentUI) {
                    runtimeState.records.append(record)
                    changedRecords.append(record)
                } else {
                    unchangedCount += 1
                }
                focusedState.parentIdentity = parent
            } catch {
                skippedCount += 1
                warnings.append("Firefox parent priority could not be changed.")
            }
        } else if classified.parent == nil {
            focusedState.parentIdentity = nil
        }

        let gpuReconciled = reconcileFocusedRole(
            role: .gpuHelper,
            desiredIdentity: classified.gpu,
            warnings: &warnings
        )
        if gpuReconciled, let gpu = classified.gpu {
            do {
                if let record = try ensureFocusedPriority(identity: gpu, role: .gpuHelper) {
                    runtimeState.records.append(record)
                    changedRecords.append(record)
                } else {
                    unchangedCount += 1
                }
                focusedState.gpuIdentity = gpu
            } catch {
                skippedCount += 1
                warnings.append("Firefox GPU helper priority could not be changed.")
            }
        } else if classified.gpu == nil {
            focusedState.gpuIdentity = nil
        }

        var cpuByPID: [Int32: UInt64] = [:]
        for identity in classified.contentStyle {
            do {
                let fresh = try inspector.process(pid: identity.pid)
                guard identity.matchesForMutation(fresh) else {
                    skippedCount += 1
                    continue
                }
                cpuByPID[identity.pid] = try activityInspector.cpuTimeNanoseconds(pid: identity.pid)
                let verified = try inspector.process(pid: identity.pid)
                guard identity.matchesForMutation(verified) else {
                    cpuByPID.removeValue(forKey: identity.pid)
                    skippedCount += 1
                    continue
                }
            } catch {
                skippedCount += 1
            }
        }

        let previousSelectionState = focusedState.contentSelectionState
        let evaluation = contentSelector.evaluate(
            processes: classified.contentStyle,
            cumulativeCPUByPID: cpuByPID,
            state: previousSelectionState
        )
        var acceptedSelectionState = evaluation.state

        switch evaluation.decision {
        case .keepCurrent:
            focusedState.contentTargetIdentity = evaluation.state.currentTarget

        case .clearExitedTarget:
            removeExitedContentRecordIfNeeded()
            focusedState.contentTargetIdentity = nil

        case .select(let pid):
            if let target = classified.contentStyle.first(where: { $0.pid == pid }) {
                do {
                    if let record = try ensureFocusedPriority(identity: target, role: .contentTarget) {
                        runtimeState.records.append(record)
                        changedRecords.append(record)
                    } else {
                        unchangedCount += 1
                    }
                    focusedState.contentTargetIdentity = target
                } catch {
                    skippedCount += 1
                    warnings.append("Firefox content priority could not be changed.")
                    acceptedSelectionState = selectionStateAfterRejectedTarget(
                        evaluation.state,
                        fallbackTarget: previousSelectionState.currentTarget
                    )
                    focusedState.contentTargetIdentity = previousSelectionState.currentTarget
                }
            }

        case .switchTarget(let oldPID, let newPID):
            let oldRecord = runtimeState.records.first(where: {
                $0.role == .contentTarget && $0.identity.pid == oldPID && $0.didChangePriority
            })
            var maySelectReplacement = true
            if let record = oldRecord {
                switch restoreSingleRecord(record) {
                case .restored, .exited:
                    removeRecord(matching: record)
                case .mismatched(let outstanding), .failed(let outstanding):
                    replaceRecord(outstanding)
                    maySelectReplacement = false
                    warnings.append("Previous Firefox content priority could not be restored; target switch was blocked.")
                }
            }

            if maySelectReplacement,
               let target = classified.contentStyle.first(where: { $0.pid == newPID }) {
                do {
                    if let record = try ensureFocusedPriority(identity: target, role: .contentTarget) {
                        runtimeState.records.append(record)
                        changedRecords.append(record)
                    } else {
                        unchangedCount += 1
                    }
                    focusedState.contentTargetIdentity = target
                } catch {
                    skippedCount += 1
                    warnings.append("Replacement Firefox content priority could not be changed.")
                    acceptedSelectionState = selectionStateAfterRejectedTarget(
                        evaluation.state,
                        fallbackTarget: nil
                    )
                    focusedState.contentTargetIdentity = nil
                }
            } else if !maySelectReplacement {
                acceptedSelectionState = FocusedFirefoxContentSelectionState(
                    priorCounters: evaluation.state.priorCounters,
                    currentTarget: previousSelectionState.currentTarget,
                    candidateIdentity: nil,
                    candidateWinCount: 0
                )
                focusedState.contentTargetIdentity = previousSelectionState.currentTarget
            }
        }

        focusedState.contentSelectionState = acceptedSelectionState
        focusedState.trackedProcessCount = classified.trackedProcessCount
        focusedState.warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        runtimeState.policyKind = policy.kind
        runtimeState.focusedFirefoxState = focusedState

        let focusedRecords = focusedChangedRecords()
        if focusedRecords.count > (policy.maximumBoostedCount ?? 3) {
            throw AppPriorityProcessError.invalidProcessData(pid: focusedRecords.last?.identity.pid ?? -1)
        }

        try stateStore.writeRuntimeState(runtimeState)
        let details = FocusedFirefoxStatusDetails(
            trackedProcessCount: classified.trackedProcessCount,
            actuallyBoostedCount: focusedRecords.count,
            parentPID: focusedRecords.first(where: { $0.role == .parentUI })?.identity.pid,
            gpuPID: focusedRecords.first(where: { $0.role == .gpuHelper })?.identity.pid,
            contentPID: focusedRecords.first(where: { $0.role == .contentTarget })?.identity.pid,
            waitingForStableContent: focusedState.contentTargetIdentity == nil && !classified.contentStyle.isEmpty,
            warning: focusedState.warning
        )
        return AppPriorityScanOutcome(
            changedRecords: changedRecords,
            boostedCount: focusedRecords.count,
            unchangedCount: unchangedCount,
            skippedCount: skippedCount,
            mainProcessFound: family.mainProcessFound,
            trackedProcessCount: classified.trackedProcessCount,
            focusedFirefox: details
        )
    }

    private func ensureFocusedPriority(
        identity: AppPriorityProcessIdentity,
        role: AppPriorityBoostRole
    ) throws -> AppPriorityRestoreRecord? {
        if let existing = runtimeState.records.first(where: {
            $0.role == role && $0.identity.matchesForMutation(identity) && $0.didChangePriority
        }) {
            _ = existing
            return nil
        }
        let limit = policy.maximumBoostedCount ?? 3
        guard focusedChangedRecords().count < limit else {
            throw AppPriorityProcessError.priorityWriteFailed(pid: identity.pid, code: -1)
        }
        return try ensurePriority(identity: identity, role: role, targetNiceValue: policy.targetNiceValue)
    }

    private func ensurePriority(
        identity: AppPriorityProcessIdentity,
        role: AppPriorityBoostRole,
        targetNiceValue: Int32
    ) throws -> AppPriorityRestoreRecord? {
        let freshBeforeRead = try inspector.process(pid: identity.pid)
        guard identity.matchesForMutation(freshBeforeRead) else {
            throw AppPriorityProcessError.invalidProcessData(pid: identity.pid)
        }
        let originalPriority = try mutator.priority(pid: identity.pid)
        if originalPriority <= targetNiceValue {
            return nil
        }
        let freshBeforeWrite = try inspector.process(pid: identity.pid)
        guard identity.matchesForMutation(freshBeforeWrite) else {
            throw AppPriorityProcessError.invalidProcessData(pid: identity.pid)
        }
        try mutator.setPriority(pid: identity.pid, value: targetNiceValue)
        let freshAfterWrite = try inspector.process(pid: identity.pid)
        let observedPriority = try mutator.priority(pid: identity.pid)
        guard identity.matchesForMutation(freshAfterWrite), observedPriority == targetNiceValue else {
            throw AppPriorityProcessError.priorityWriteFailed(pid: identity.pid, code: -1)
        }
        return AppPriorityRestoreRecord(
            identity: identity,
            originalNiceValue: originalPriority,
            didChangePriority: true,
            lastObservedStatus: .changed,
            errorMessage: nil,
            role: role
        )
    }

    private func reconcileFocusedRole(
        role: AppPriorityBoostRole,
        desiredIdentity: AppPriorityProcessIdentity?,
        warnings: inout [String]
    ) -> Bool {
        let records = runtimeState.records.filter { $0.role == role && $0.didChangePriority }
        var replacementAllowed = true
        for record in records {
            if let desired = desiredIdentity, record.identity.matchesForMutation(desired) {
                continue
            }
            switch restoreSingleRecord(record) {
            case .restored, .exited:
                removeRecord(matching: record)
            case .mismatched(let outstanding), .failed(let outstanding):
                replaceRecord(outstanding)
                replacementAllowed = false
                warnings.append("A previous focused Firefox role still requires restoration.")
            }
        }
        return replacementAllowed
    }

    private func restoreSingleRecord(_ record: AppPriorityRestoreRecord) -> AppPrioritySingleRestoreResult {
        var updated = record
        let current: AppPriorityProcessIdentity
        do {
            current = try inspector.process(pid: record.identity.pid)
        } catch {
            updated.lastObservedStatus = .exited
            updated.errorMessage = nil
            return .exited
        }
        guard record.identity.matchesForMutation(current) else {
            updated.lastObservedStatus = .mismatched
            updated.errorMessage = "PID identity no longer matches"
            return .mismatched(updated)
        }
        do {
            try mutator.setPriority(pid: record.identity.pid, value: record.originalNiceValue)
            let verifiedIdentity = try inspector.process(pid: record.identity.pid)
            let verifiedPriority = try mutator.priority(pid: record.identity.pid)
            guard record.identity.matchesForMutation(verifiedIdentity),
                  verifiedPriority == record.originalNiceValue else {
                updated.lastObservedStatus = .failed
                updated.errorMessage = "Priority restoration could not be verified"
                return .failed(updated)
            }
            updated.lastObservedStatus = .restored
            updated.errorMessage = nil
            return .restored
        } catch {
            updated.lastObservedStatus = .failed
            updated.errorMessage = String(error.localizedDescription.prefix(256))
            return .failed(updated)
        }
    }

    private func removeExitedContentRecordIfNeeded() {
        let records = runtimeState.records.filter { $0.role == .contentTarget }
        for record in records {
            switch restoreSingleRecord(record) {
            case .restored, .exited:
                removeRecord(matching: record)
            case .mismatched(let outstanding), .failed(let outstanding):
                replaceRecord(outstanding)
            }
        }
    }

    private func selectionStateAfterRejectedTarget(
        _ state: FocusedFirefoxContentSelectionState,
        fallbackTarget: AppPriorityProcessIdentity?
    ) -> FocusedFirefoxContentSelectionState {
        return FocusedFirefoxContentSelectionState(
            priorCounters: state.priorCounters,
            currentTarget: fallbackTarget,
            candidateIdentity: nil,
            candidateWinCount: 0
        )
    }

    private func focusedChangedRecords() -> [AppPriorityRestoreRecord] {
        return runtimeState.records.filter {
            $0.didChangePriority && ($0.role == .parentUI || $0.role == .gpuHelper || $0.role == .contentTarget)
        }
    }

    private func actualChangedRecordCount() -> Int {
        return runtimeState.records.filter { $0.didChangePriority }.count
    }

    private func removeRecord(matching record: AppPriorityRestoreRecord) {
        runtimeState.records.removeAll {
            $0.identity.matchesForMutation(record.identity) && $0.role == record.role
        }
    }

    private func replaceRecord(_ record: AppPriorityRestoreRecord) {
        if let index = runtimeState.records.firstIndex(where: {
            $0.identity.matchesForMutation(record.identity) && $0.role == record.role
        }) {
            runtimeState.records[index] = record
        } else {
            runtimeState.records.append(record)
        }
    }

    private func identitiesMatch(
        _ left: AppPriorityProcessIdentity?,
        _ right: AppPriorityProcessIdentity?
    ) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.matchesForMutation(rhs)
        default: return false
        }
    }

    public func run() throws -> AppPriorityRestoreOutcome {
        try stateStore.prepareDirectories()
        try stateStore.writeRuntimeState(runtimeState)
        try stateStore.writeStatus(makeStatus(
            state: .starting,
            skippedCount: 0,
            message: "Starting App Priority monitor"
        ))

        while !stateStore.stopRequested() {
            do {
                let outcome = try scanOnce()
                let state: AppPriorityStatus.State
                let message: String
                if !outcome.mainProcessFound {
                    state = .waitingForSelectedApp
                    message = "Waiting for selected application"
                } else if outcome.skippedCount > 0 {
                    state = .activeWithSkipped
                    message = "Active with skipped processes"
                } else if outcome.focusedFirefox?.waitingForStableContent == true {
                    state = .active
                    message = "Waiting for stable active content process"
                } else {
                    state = .active
                    message = "App Priority active"
                }
                try stateStore.writeStatus(AppPriorityStatus(
                    state: state,
                    boostedCount: outcome.boostedCount,
                    skippedCount: outcome.skippedCount,
                    message: "\(message) — \(policy.summary)",
                    sessionIdentifier: sessionIdentifier,
                    targetNiceValue: policy.targetNiceValue,
                    targetScope: policy.legacyScope,
                    policyKind: policy.kind,
                    focusedFirefox: outcome.focusedFirefox
                ))
            } catch {
                try? stateStore.writeStatus(makeStatus(
                    state: .failed,
                    skippedCount: 1,
                    message: String(error.localizedDescription.prefix(256))
                ))
            }
            if !stateStore.stopRequested() {
                clock.sleep(seconds: 2.0)
            }
        }
        return try restoreOutstandingRecords(runtimeState.records)
    }

    private func makeStatus(
        state: AppPriorityStatus.State,
        skippedCount: Int,
        message: String
    ) -> AppPriorityStatus {
        let focusedDetails: FocusedFirefoxStatusDetails?
        if let focused = runtimeState.focusedFirefoxState, policy.kind == .focusedFirefox {
            let records = focusedChangedRecords()
            focusedDetails = FocusedFirefoxStatusDetails(
                trackedProcessCount: focused.trackedProcessCount,
                actuallyBoostedCount: records.count,
                parentPID: records.first(where: { $0.role == .parentUI })?.identity.pid,
                gpuPID: records.first(where: { $0.role == .gpuHelper })?.identity.pid,
                contentPID: records.first(where: { $0.role == .contentTarget })?.identity.pid,
                waitingForStableContent: focused.contentTargetIdentity == nil,
                warning: focused.warning
            )
        } else {
            focusedDetails = nil
        }
        return AppPriorityStatus(
            state: state,
            boostedCount: actualChangedRecordCount(),
            skippedCount: skippedCount,
            message: "\(message) — \(policy.summary)",
            sessionIdentifier: sessionIdentifier,
            targetNiceValue: policy.targetNiceValue,
            targetScope: policy.legacyScope,
            policyKind: policy.kind,
            focusedFirefox: focusedDetails
        )
    }

    public func restoreOutstandingRecords(_ records: [AppPriorityRestoreRecord]) throws -> AppPriorityRestoreOutcome {
        var restoredCount = 0
        var exitedCount = 0
        var mismatchedCount = 0
        var failedCount = 0
        var outstanding: [AppPriorityRestoreRecord] = []

        for record in orderedRecordsForRestore(records) where record.didChangePriority {
            switch restoreSingleRecord(record) {
            case .restored:
                restoredCount += 1
            case .exited:
                exitedCount += 1
            case .mismatched(let updated):
                outstanding.append(updated)
                mismatchedCount += 1
            case .failed(let updated):
                outstanding.append(updated)
                failedCount += 1
            }
        }

        runtimeState.records = outstanding
        if outstanding.isEmpty {
            try stateStore.writeStatus(AppPriorityStatus(
                state: .restored,
                boostedCount: 0,
                skippedCount: 0,
                message: "App Priority restored — \(policy.summary)",
                sessionIdentifier: sessionIdentifier,
                targetNiceValue: policy.targetNiceValue,
                targetScope: policy.legacyScope,
                policyKind: policy.kind,
                focusedFirefox: nil
            ))
            stateStore.removeRuntimeFilesAfterSuccessfulRestore()
        } else {
            try stateStore.writeRuntimeState(runtimeState)
            try stateStore.writeStatus(AppPriorityStatus(
                state: .restorePending,
                boostedCount: outstanding.count,
                skippedCount: mismatchedCount + failedCount,
                message: "Some process priorities still require restoration — \(policy.summary)",
                sessionIdentifier: sessionIdentifier,
                targetNiceValue: policy.targetNiceValue,
                targetScope: policy.legacyScope,
                policyKind: policy.kind,
                focusedFirefox: makeStatus(state: .restorePending, skippedCount: 0, message: "").focusedFirefox
            ))
        }

        return AppPriorityRestoreOutcome(
            restoredCount: restoredCount,
            exitedCount: exitedCount,
            mismatchedCount: mismatchedCount,
            failedCount: failedCount,
            outstandingRecords: outstanding
        )
    }

    private func orderedRecordsForRestore(_ records: [AppPriorityRestoreRecord]) -> [AppPriorityRestoreRecord] {
        guard policy.kind == .focusedFirefox else { return records }
        func rank(_ role: AppPriorityBoostRole?) -> Int {
            switch role {
            case .contentTarget?: return 0
            case .gpuHelper?: return 1
            case .parentUI?: return 2
            case .generic?, nil: return 3
            }
        }
        return records.enumerated().sorted {
            let left = rank($0.element.role)
            let right = rank($1.element.role)
            if left == right { return $0.offset < $1.offset }
            return left < right
        }.map { $0.element }
    }
}
