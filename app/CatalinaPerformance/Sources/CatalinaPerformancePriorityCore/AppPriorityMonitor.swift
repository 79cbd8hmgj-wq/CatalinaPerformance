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

    public init(changedRecords: [AppPriorityRestoreRecord], boostedCount: Int, unchangedCount: Int, skippedCount: Int, mainProcessFound: Bool) {
        self.changedRecords = changedRecords
        self.boostedCount = boostedCount
        self.unchangedCount = unchangedCount
        self.skippedCount = skippedCount
        self.mainProcessFound = mainProcessFound
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

public final class AppPriorityMonitor {
    public static let targetNiceValue: Int32 = -5

    private let selection: ValidatedAppPrioritySelection
    private let inspector: AppPriorityProcessInspecting
    private let mutator: AppPriorityPriorityMutating
    private let stateStore: AppPriorityStateStore
    private let clock: AppPriorityMonitorClock
    private let sessionIdentifier: String
    private var runtimeState: AppPriorityRuntimeState

    public init(
        selection: ValidatedAppPrioritySelection,
        inspector: AppPriorityProcessInspecting,
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
        self.mutator = mutator
        self.stateStore = stateStore
        self.clock = clock
        self.sessionIdentifier = sessionIdentifier
        if let existing = stateStore.runtimeStateIfPresent(),
           existing.sessionIdentifier == sessionIdentifier,
           existing.requestingUID == selection.requestingUID,
           existing.selectedApplication == application {
            self.runtimeState = existing
        } else {
            self.runtimeState = AppPriorityRuntimeState(
                sessionIdentifier: sessionIdentifier,
                selectedApplication: application,
                requestingUID: selection.requestingUID,
                monitorIdentity: monitorIdentity,
                records: [],
                startedAt: startedAt
            )
        }
    }

    public func scanOnce() throws -> AppPriorityScanOutcome {
        guard let application = selection.application else {
            throw AppPriorityValidationError.featureEnabledWithoutApplication
        }
        let snapshot = try inspector.allProcesses()
        let family = AppPriorityProcessFamilyResolver.resolve(
            application: application,
            requestingUID: selection.requestingUID,
            processes: snapshot
        )
        var changedRecords: [AppPriorityRestoreRecord] = []
        var boostedCount = 0
        var unchangedCount = 0
        var skippedCount = family.skipped.count

        for candidate in family.eligible {
            if runtimeState.records.contains(where: { $0.identity.matchesForMutation(candidate) && $0.didChangePriority }) {
                boostedCount += 1
                continue
            }
            do {
                let freshBeforeRead = try inspector.process(pid: candidate.pid)
                guard candidate.matchesForMutation(freshBeforeRead) else {
                    skippedCount += 1
                    continue
                }
                let originalPriority = try mutator.priority(pid: candidate.pid)
                if originalPriority <= Self.targetNiceValue {
                    unchangedCount += 1
                    continue
                }
                let freshBeforeWrite = try inspector.process(pid: candidate.pid)
                guard candidate.matchesForMutation(freshBeforeWrite) else {
                    skippedCount += 1
                    continue
                }
                try mutator.setPriority(pid: candidate.pid, value: Self.targetNiceValue)
                let freshAfterWrite = try inspector.process(pid: candidate.pid)
                let observedPriority = try mutator.priority(pid: candidate.pid)
                guard candidate.matchesForMutation(freshAfterWrite), observedPriority == Self.targetNiceValue else {
                    skippedCount += 1
                    continue
                }
                let record = AppPriorityRestoreRecord(
                    identity: candidate,
                    originalNiceValue: originalPriority,
                    didChangePriority: true,
                    lastObservedStatus: .changed,
                    errorMessage: nil
                )
                runtimeState.records.append(record)
                changedRecords.append(record)
                boostedCount += 1
            } catch {
                skippedCount += 1
            }
        }

        try stateStore.writeRuntimeState(runtimeState)
        return AppPriorityScanOutcome(
            changedRecords: changedRecords,
            boostedCount: boostedCount,
            unchangedCount: unchangedCount,
            skippedCount: skippedCount,
            mainProcessFound: family.mainProcessFound
        )
    }

    public func run() throws -> AppPriorityRestoreOutcome {
        try stateStore.prepareDirectories()
        try stateStore.writeRuntimeState(runtimeState)
        try stateStore.writeStatus(AppPriorityStatus(
            state: .starting,
            boostedCount: runtimeState.records.count,
            skippedCount: 0,
            message: "Starting App Priority monitor",
            sessionIdentifier: sessionIdentifier
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
                } else {
                    state = .active
                    message = "App Priority active"
                }
                try stateStore.writeStatus(AppPriorityStatus(
                    state: state,
                    boostedCount: runtimeState.records.count,
                    skippedCount: outcome.skippedCount,
                    message: message,
                    sessionIdentifier: sessionIdentifier
                ))
            } catch {
                try? stateStore.writeStatus(AppPriorityStatus(
                    state: .failed,
                    boostedCount: runtimeState.records.count,
                    skippedCount: 1,
                    message: String(error.localizedDescription.prefix(256)),
                    sessionIdentifier: sessionIdentifier
                ))
            }
            if !stateStore.stopRequested() {
                clock.sleep(seconds: 2.0)
            }
        }
        return try restoreOutstandingRecords(runtimeState.records)
    }

    public func restoreOutstandingRecords(_ records: [AppPriorityRestoreRecord]) throws -> AppPriorityRestoreOutcome {
        var restoredCount = 0
        var exitedCount = 0
        var mismatchedCount = 0
        var failedCount = 0
        var outstanding: [AppPriorityRestoreRecord] = []

        for var record in records where record.didChangePriority {
            let current: AppPriorityProcessIdentity
            do {
                current = try inspector.process(pid: record.identity.pid)
            } catch {
                record.lastObservedStatus = .exited
                record.errorMessage = nil
                exitedCount += 1
                continue
            }
            guard record.identity.matchesForMutation(current) else {
                record.lastObservedStatus = .mismatched
                record.errorMessage = "PID identity no longer matches"
                outstanding.append(record)
                mismatchedCount += 1
                continue
            }
            do {
                try mutator.setPriority(pid: record.identity.pid, value: record.originalNiceValue)
                let verifiedIdentity = try inspector.process(pid: record.identity.pid)
                let verifiedPriority = try mutator.priority(pid: record.identity.pid)
                guard record.identity.matchesForMutation(verifiedIdentity), verifiedPriority == record.originalNiceValue else {
                    record.lastObservedStatus = .failed
                    record.errorMessage = "Priority restoration could not be verified"
                    outstanding.append(record)
                    failedCount += 1
                    continue
                }
                record.lastObservedStatus = .restored
                record.errorMessage = nil
                restoredCount += 1
            } catch {
                record.lastObservedStatus = .failed
                record.errorMessage = String(error.localizedDescription.prefix(256))
                outstanding.append(record)
                failedCount += 1
            }
        }

        runtimeState.records = outstanding
        if outstanding.isEmpty {
            try stateStore.writeStatus(AppPriorityStatus(
                state: .restored,
                boostedCount: 0,
                skippedCount: 0,
                message: "App Priority restored",
                sessionIdentifier: sessionIdentifier
            ))
            stateStore.removeRuntimeFilesAfterSuccessfulRestore()
        } else {
            try stateStore.writeRuntimeState(runtimeState)
            try stateStore.writeStatus(AppPriorityStatus(
                state: .restorePending,
                boostedCount: outstanding.count,
                skippedCount: mismatchedCount + failedCount,
                message: "Some process priorities still require restoration",
                sessionIdentifier: sessionIdentifier
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
}
