import Foundation
import CatalinaPerformancePriorityCore

public protocol MemoryManagementCoordinating: AnyObject {
    func prepareSession(identifier: String, at date: Date) throws -> MemoryManagementStatusSnapshot
    @discardableResult
    func updateFrontmostApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot
    @discardableResult
    func updateAppPriorityApplication(_ application: AppPriorityApplication?, at date: Date) -> MemoryManagementStatusSnapshot
    func evaluate(telemetry: MemoryTelemetrySnapshot) -> MemoryManagementStatusSnapshot
    func requestImmediateRestore(at date: Date) -> MemoryManagementStatusSnapshot
    func currentStatus(at date: Date) -> MemoryManagementStatusSnapshot
}

public final class MemoryManagementCoordinator: MemoryManagementCoordinating {
    private let desiredStateStore: MemoryDesiredStateStoring
    private let processInspector: AppPriorityProcessInspecting
    private let resourceInspector: AppPriorityProcessResourceInspecting
    private let requestingUID: UInt32
    private let backgroundServiceRecheck: () -> Void
    private let lock = NSLock()

    private var classifier: MemoryPressureClassifier
    private var analyzer: MemoryProcessFamilyAnalyzer
    private var sessionIdentifier: String?
    private var generation: UInt64 = 0
    private var desiredFamilies: [MemoryDesiredFamily] = []
    private var frontmostApplication: AppPriorityApplication?
    private var appPriorityApplication: AppPriorityApplication?
    private var stopRequested = false
    private var lastTelemetry: MemoryTelemetrySnapshot?
    private var lastPressureState: MemoryPressureState = .healthy
    private var lastNote: String?

    public init(
        desiredStateStore: MemoryDesiredStateStoring,
        processInspector: AppPriorityProcessInspecting,
        resourceInspector: AppPriorityProcessResourceInspecting,
        requestingUID: UInt32,
        backgroundServiceRecheck: @escaping () -> Void = {}
    ) {
        self.desiredStateStore = desiredStateStore
        self.processInspector = processInspector
        self.resourceInspector = resourceInspector
        self.requestingUID = requestingUID
        self.backgroundServiceRecheck = backgroundServiceRecheck
        self.classifier = MemoryPressureClassifier()
        self.analyzer = MemoryProcessFamilyAnalyzer()
    }

    public func prepareSession(identifier: String, at date: Date) throws -> MemoryManagementStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard requestingUID > 0, !identifier.isEmpty, identifier.count <= 128 else {
            throw MemoryDesiredStateStoreError.unsafeDesiredState
        }

        let existing = try desiredStateStore.load()
        let startingGeneration: UInt64
        if let existingValue = existing, existingValue.sessionIdentifier == identifier {
            startingGeneration = existingValue.generation
        } else {
            startingGeneration = 0
        }

        sessionIdentifier = identifier
        generation = startingGeneration
        desiredFamilies = []
        stopRequested = false
        lastTelemetry = nil
        lastPressureState = .healthy
        lastNote = "Memory Pressure Management is armed and waiting for sustained pressure."
        classifier = MemoryPressureClassifier()
        analyzer = MemoryProcessFamilyAnalyzer()

        do {
            try saveDesiredStateLocked(families: [], shouldStopAndRestore: false)
        } catch {
            sessionIdentifier = nil
            generation = 0
            desiredFamilies = []
            stopRequested = false
            lastNote = "Memory Pressure Management could not be armed: \(error)"
            throw error
        }
        return statusLocked(at: date)
    }

    @discardableResult
    public func updateFrontmostApplication(
        _ application: AppPriorityApplication?,
        at date: Date
    ) -> MemoryManagementStatusSnapshot {
        lock.lock()
        frontmostApplication = application
        let filtered = desiredFamiliesExcludingConflictsLocked()
        if filtered != desiredFamilies {
            _ = persistFamiliesLocked(
                filtered,
                noteOnFailure: "Foreground protection could not be persisted."
            )
        }
        let result = statusLocked(at: date)
        lock.unlock()
        return result
    }

    @discardableResult
    public func updateAppPriorityApplication(
        _ application: AppPriorityApplication?,
        at date: Date
    ) -> MemoryManagementStatusSnapshot {
        lock.lock()
        appPriorityApplication = application
        let filtered = desiredFamiliesExcludingConflictsLocked()
        if filtered != desiredFamilies {
            _ = persistFamiliesLocked(
                filtered,
                noteOnFailure: "App Priority conflict removal could not be persisted."
            )
        }
        let result = statusLocked(at: date)
        lock.unlock()
        return result
    }

    public func evaluate(telemetry: MemoryTelemetrySnapshot) -> MemoryManagementStatusSnapshot {
        var shouldRecheckBackgroundServices = false
        lock.lock()

        lastTelemetry = telemetry
        guard sessionIdentifier != nil, !stopRequested else {
            lastNote = stopRequested
                ? "Memory Pressure Management is waiting for session restoration to finish."
                : "Memory Pressure Management is not armed for a Performance Mode session."
            let result = statusLocked(at: telemetry.capturedAt)
            lock.unlock()
            return result
        }

        let wasActiveBeforeEvaluation = !desiredFamilies.isEmpty
        let conflictFiltered = desiredFamiliesExcludingConflictsLocked()
        if conflictFiltered != desiredFamilies {
            _ = persistFamiliesLocked(
                conflictFiltered,
                noteOnFailure: "Protected foreground/App Priority removal could not be persisted."
            )
        }

        guard telemetry.counters != nil else {
            classifier = MemoryPressureClassifier()
            lastPressureState = .healthy
            if !desiredFamilies.isEmpty {
                _ = persistFamiliesLocked(
                    [],
                    noteOnFailure: "Unavailable telemetry restore request could not be persisted."
                )
            }
            if desiredFamilies.isEmpty {
                lastNote = telemetry.note ?? "Memory VM telemetry is unavailable; automatic intervention is disabled."
            }
            let result = statusLocked(at: telemetry.capturedAt)
            lock.unlock()
            return result
        }

        let candidates: [MemoryProcessFamilyCandidate]
        do {
            let processes = try processInspector.allProcesses()
            let physicalBytes = telemetry.counters?.physicalBytes ?? 0
            candidates = analyzer.rankEligibleFamilies(
                processes: processes,
                currentUID: requestingUID,
                physicalBytes: physicalBytes,
                frontmostApplication: frontmostApplication,
                appPriorityApplication: appPriorityApplication,
                resourceInspector: resourceInspector
            )
        } catch {
            if !desiredFamilies.isEmpty {
                _ = persistFamiliesLocked(
                    [],
                    noteOnFailure: "Process verification failure restore request could not be persisted."
                )
            }
            if desiredFamilies.isEmpty {
                lastNote = "Process-family verification failed; automatic memory scheduling is idle: \(error)"
            }
            let result = statusLocked(at: telemetry.capturedAt)
            lock.unlock()
            return result
        }

        let evaluation = classifier.evaluate(
            snapshot: telemetry,
            interventionActive: !desiredFamilies.isEmpty
        )
        lastPressureState = evaluation.confirmedState

        if evaluation.shouldRestore {
            if !desiredFamilies.isEmpty {
                _ = persistFamiliesLocked(
                    [],
                    noteOnFailure: "Healthy recovery restore request could not be persisted."
                )
            }
            if desiredFamilies.isEmpty {
                lastNote = "Memory pressure remained healthy long enough to restore managed workloads."
            }
        } else if evaluation.shouldIntervene {
            let newFamilies = desiredFamiliesFromCandidates(candidates)
            if newFamilies != desiredFamilies {
                _ = persistFamiliesLocked(
                    newFamilies,
                    noteOnFailure: "Memory intervention desired state could not be persisted."
                )
            }
            if desiredFamilies.isEmpty {
                if lastNote == nil || lastNote?.contains("could not be persisted") == false {
                    lastNote = "Sustained memory pressure is confirmed, but no verified noncritical background workload currently qualifies."
                }
            } else {
                lastNote = "Sustained memory pressure confirmed; verified background workloads are temporarily scheduled at nice +5."
            }
        } else if evaluation.confirmedState == .elevated {
            lastNote = "Memory pressure is elevated; automatic intervention remains idle until High or Critical is sustained."
        } else if !desiredFamilies.isEmpty {
            lastNote = "Memory pressure is recovering; managed workloads remain deprioritized until the healthy recovery window completes."
        } else {
            lastNote = "Memory pressure is healthy; no scheduling intervention is active."
        }

        let isActiveAfterEvaluation = !desiredFamilies.isEmpty
        shouldRecheckBackgroundServices = !wasActiveBeforeEvaluation && isActiveAfterEvaluation
        let result = statusLocked(at: telemetry.capturedAt)
        lock.unlock()

        if shouldRecheckBackgroundServices {
            backgroundServiceRecheck()
        }
        return result
    }

    public func requestImmediateRestore(at date: Date) -> MemoryManagementStatusSnapshot {
        lock.lock()
        stopRequested = true
        do {
            try saveDesiredStateLocked(families: [], shouldStopAndRestore: true)
            desiredFamilies = []
            lastNote = "Immediate Memory Management restoration was requested."
        } catch {
            lastNote = "Immediate Memory Management restoration request could not be persisted: \(error)"
        }
        let result = statusLocked(at: date)
        lock.unlock()
        return result
    }

    public func currentStatus(at date: Date) -> MemoryManagementStatusSnapshot {
        lock.lock()
        let result = statusLocked(at: date)
        lock.unlock()
        return result
    }

    private func desiredFamiliesFromCandidates(
        _ candidates: [MemoryProcessFamilyCandidate]
    ) -> [MemoryDesiredFamily] {
        return candidates.map { candidate in
            let processes = candidate.processes.map { observation in
                MemoryDesiredProcess(
                    identity: observation.identity,
                    familyIdentifier: candidate.identifier,
                    requestedNiceValue: 5
                )
            }
            return MemoryDesiredFamily(
                identifier: candidate.identifier,
                displayName: candidate.displayName,
                bundlePath: candidate.bundlePath,
                processes: processes
            )
        }
    }

    private func desiredFamiliesExcludingConflictsLocked() -> [MemoryDesiredFamily] {
        guard !desiredFamilies.isEmpty else { return [] }
        let frontmostIdentifier = frontmostApplication.map { canonicalBundleIdentifier($0.bundlePath) }
        let priorityIdentifier = appPriorityApplication.map { canonicalBundleIdentifier($0.bundlePath) }
        return desiredFamilies.filter { family in
            family.identifier != frontmostIdentifier && family.identifier != priorityIdentifier
        }
    }

    @discardableResult
    private func persistFamiliesLocked(
        _ families: [MemoryDesiredFamily],
        noteOnFailure: String
    ) -> Bool {
        do {
            try saveDesiredStateLocked(families: families, shouldStopAndRestore: false)
            desiredFamilies = families
            return true
        } catch {
            lastNote = "\(noteOnFailure) \(error)"
            return false
        }
    }

    private func saveDesiredStateLocked(
        families: [MemoryDesiredFamily],
        shouldStopAndRestore: Bool
    ) throws {
        guard let identifier = sessionIdentifier else {
            throw MemoryDesiredStateStoreError.unsafeDesiredState
        }
        let nextGeneration = generation + 1
        let state = MemoryDesiredState(
            sessionIdentifier: identifier,
            requestingUID: requestingUID,
            generation: nextGeneration,
            shouldStopAndRestore: shouldStopAndRestore,
            families: families
        )
        try desiredStateStore.save(state)
        generation = nextGeneration
    }

    private func statusLocked(at date: Date) -> MemoryManagementStatusSnapshot {
        let names = desiredFamilies.map { $0.displayName }
        let ioStatus: MemoryIOPolicyStatus = CatalinaMemoryCapabilities.current.taskPolicy
            ? (!desiredFamilies.isEmpty ? .active : .available)
            : .unsupported
        return MemoryManagementStatusSnapshot(
            capturedAt: date,
            pressureState: lastPressureState,
            managedFamilyCount: desiredFamilies.count,
            managedFamilyNames: names,
            interventionActive: !desiredFamilies.isEmpty,
            ioPolicyStatus: ioStatus,
            telemetry: lastTelemetry,
            note: lastNote
        )
    }

    private func canonicalBundleIdentifier(_ path: String) -> String {
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
            .lowercased()
    }
}
