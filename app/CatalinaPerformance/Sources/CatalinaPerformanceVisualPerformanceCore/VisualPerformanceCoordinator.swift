import Foundation

public protocol VisualPreferenceOperating: AnyObject {
    func read(_ entry: VisualSettingCatalogEntry) throws -> VisualPreferenceObservation
    func writeAppliedValue(_ entry: VisualSettingCatalogEntry) throws
    func write(_ value: VisualScalarValue, for entry: VisualSettingCatalogEntry) throws
    func delete(_ entry: VisualSettingCatalogEntry) throws
    func isDockAutoHideEnabled() throws -> Bool
}

public enum VisualPerformanceRestoreReason: String, Codable {
    case normalOff
    case onRollback
    case emergencyRestore
    case staleRecovery
    case retry
}

public struct VisualCurrentSetting: Equatable {
    public let id: VisualSettingID
    public let displayName: String
    public let observation: VisualPreferenceObservation
    public let note: String?

    public init(id: VisualSettingID, displayName: String, observation: VisualPreferenceObservation, note: String?) {
        self.id = id
        self.displayName = displayName
        self.observation = observation
        self.note = note
    }
}

public final class VisualPerformanceCoordinator {
    public typealias SnapshotHandler = (VisualPerformanceStatusSnapshot) -> Void

    private let catalog: CatalinaVisualPerformanceCatalog
    private let preferenceOperator: VisualPreferenceOperating
    private let stateStore: VisualPerformanceStateStoring
    private let requestingUID: UInt32
    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let nowProvider: () -> Date
    private let sessionIdentifierProvider: () -> String

    public var onSnapshot: SnapshotHandler?

    public init(
        catalog: CatalinaVisualPerformanceCatalog = .current,
        preferenceOperator: VisualPreferenceOperating,
        stateStore: VisualPerformanceStateStoring,
        requestingUID: UInt32,
        workQueue: DispatchQueue = DispatchQueue(label: "CatalinaPerformance.VisualPerformance", qos: .utility),
        callbackQueue: DispatchQueue = .main,
        nowProvider: @escaping () -> Date = Date.init,
        sessionIdentifierProvider: @escaping () -> String = { UUID().uuidString }
    ) {
        self.catalog = catalog
        self.preferenceOperator = preferenceOperator
        self.stateStore = stateStore
        self.requestingUID = requestingUID
        self.workQueue = workQueue
        self.callbackQueue = callbackQueue
        self.nowProvider = nowProvider
        self.sessionIdentifierProvider = sessionIdentifierProvider
    }

    public func prepareForPerformanceOn(completion: @escaping SnapshotHandler) {
        workQueue.async {
            let snapshot = self.prepareForPerformanceOnSynchronously()
            self.publish(snapshot, completion: completion)
        }
    }

    public func restore(reason: VisualPerformanceRestoreReason, completion: @escaping SnapshotHandler) {
        workQueue.async {
            let snapshot = self.restoreSynchronously(reason: reason)
            self.publish(snapshot, completion: completion)
        }
    }

    public func recoverStaleSession(performanceModeIsOn: Bool, completion: @escaping SnapshotHandler) {
        workQueue.async {
            let snapshot: VisualPerformanceStatusSnapshot
            do {
                if let active = try self.stateStore.loadActive() {
                    if performanceModeIsOn {
                        snapshot = self.snapshot(from: active, aggregateStatus: VisualPerformanceAggregateStatus.active(for: active.settings))
                    } else {
                        snapshot = self.restoreSynchronously(reason: .staleRecovery)
                    }
                } else if let completed = try self.stateStore.loadLastCompleted() {
                    snapshot = self.snapshot(from: completed, aggregateStatus: completed.aggregateStatus)
                } else {
                    snapshot = self.emptySnapshot()
                }
            } catch {
                snapshot = self.recoveryFailureSnapshot("Visual Performance state could not be read safely: \(error.localizedDescription)")
            }
            self.publish(snapshot, completion: completion)
        }
    }

    public func inspectCurrentSettings(completion: @escaping ([VisualCurrentSetting]) -> Void) {
        workQueue.async {
            var results: [VisualCurrentSetting] = []
            let autoHideEnabled: Bool?
            do {
                autoHideEnabled = try self.preferenceOperator.isDockAutoHideEnabled()
            } catch {
                autoHideEnabled = nil
            }
            for entry in self.catalog.entries {
                if entry.applicability == .dockAutoHideEnabled && autoHideEnabled == false {
                    results.append(VisualCurrentSetting(id: entry.id, displayName: entry.displayName, observation: .absent, note: "Not applicable because Dock auto-hide is disabled."))
                    continue
                }
                do {
                    results.append(VisualCurrentSetting(id: entry.id, displayName: entry.displayName, observation: try self.preferenceOperator.read(entry), note: nil))
                } catch {
                    results.append(VisualCurrentSetting(id: entry.id, displayName: entry.displayName, observation: .unsupportedType("read-failed"), note: error.localizedDescription))
                }
            }
            let finalResults = results
            self.callbackQueue.async { completion(finalResults) }
        }
    }

    private func prepareForPerformanceOnSynchronously() -> VisualPerformanceStatusSnapshot {
        do {
            if let existing = try stateStore.loadActive(), existing.hasOutstandingRestoration {
                return snapshot(from: existing, aggregateStatus: .recoveryRequired)
            }
        } catch {
            return recoveryFailureSnapshot("Existing Visual Performance state could not be validated: \(error.localizedDescription)")
        }

        let startedAt = nowProvider()
        let sessionIdentifier = sessionIdentifierProvider()
        let dockAutoHideEnabled: Bool?
        do {
            dockAutoHideEnabled = try preferenceOperator.isDockAutoHideEnabled()
        } catch {
            dockAutoHideEnabled = nil
        }

        var records: [VisualSettingRecord] = []
        for entry in catalog.entries {
            if entry.applicability == .dockAutoHideEnabled {
                if dockAutoHideEnabled == false {
                    records.append(makeRecord(entry: entry, prior: .absent, outcome: .notApplicable, note: "Dock auto-hide is disabled.", date: startedAt))
                    continue
                }
                if dockAutoHideEnabled == nil {
                    records.append(makeRecord(entry: entry, prior: .unsupportedType("dock-auto-hide-read-failed"), outcome: .unsupported, note: "Dock auto-hide state could not be read safely.", date: startedAt))
                    continue
                }
            }

            do {
                let prior = try preferenceOperator.read(entry)
                switch prior {
                case .absent:
                    records.append(makeRecord(entry: entry, prior: prior, outcome: .pending, note: nil, date: startedAt))
                case .present(let value):
                    guard entry.acceptedExistingTypes.contains(value.scalarType) else {
                        records.append(makeRecord(entry: entry, prior: prior, outcome: .unsupported, note: "Existing value type is not allowlisted.", date: startedAt))
                        continue
                    }
                    records.append(makeRecord(entry: entry, prior: prior, outcome: .pending, note: nil, date: startedAt))
                case .unsupportedType(let typeName):
                    records.append(makeRecord(entry: entry, prior: prior, outcome: .unsupported, note: "Unsupported existing preference type: \(typeName)", date: startedAt))
                }
            } catch {
                records.append(makeRecord(entry: entry, prior: .unsupportedType("read-failed"), outcome: .applyFailed, note: "Preflight read failed: \(error.localizedDescription)", date: startedAt))
            }
        }

        var session = VisualPerformanceSessionRecord(
            sessionIdentifier: sessionIdentifier,
            requestingUID: requestingUID,
            startedAt: startedAt,
            completedAt: nil,
            settings: records,
            aggregateStatus: VisualPerformanceAggregateStatus.active(for: records)
        )

        do {
            try stateStore.writeActive(session)
            guard let verified = try stateStore.loadActive(),
                  persistenceEquivalent(verified, session) else {
                throw VisualPerformanceStateStoreError.unsupportedOrMalformedState
            }
        } catch {
            let failedRecords = records.map { record -> VisualSettingRecord in
                if record.outcome == .pending {
                    return record.replacing(outcome: .applyFailed, note: "Visual state could not be persisted before mutation.", updatedAt: nowProvider())
                }
                return record
            }
            return VisualPerformanceStatusSnapshot(sessionIdentifier: sessionIdentifier, aggregateStatus: .failed, settings: failedRecords, updatedAt: nowProvider())
        }

        for index in records.indices {
            guard records[index].outcome == .pending, let entry = catalog[records[index].id] else { continue }
            records[index] = apply(entry: entry, record: records[index])
            session = VisualPerformanceSessionRecord(
                sessionIdentifier: sessionIdentifier,
                requestingUID: requestingUID,
                startedAt: startedAt,
                completedAt: nil,
                settings: records,
                aggregateStatus: VisualPerformanceAggregateStatus.active(for: records)
            )
            do {
                try stateStore.writeActive(session)
            } catch {
                records[index] = records[index].replacing(outcome: .recoveryRequired, note: "Applied state could not be persisted for recovery: \(error.localizedDescription)", updatedAt: nowProvider())
                session = VisualPerformanceSessionRecord(sessionIdentifier: sessionIdentifier, requestingUID: requestingUID, startedAt: startedAt, completedAt: nil, settings: records, aggregateStatus: .recoveryRequired)
                try? stateStore.writeActive(session)
                break
            }
        }

        session = VisualPerformanceSessionRecord(sessionIdentifier: sessionIdentifier, requestingUID: requestingUID, startedAt: startedAt, completedAt: nil, settings: records, aggregateStatus: VisualPerformanceAggregateStatus.active(for: records))
        try? stateStore.writeActive(session)
        return snapshot(from: session, aggregateStatus: session.aggregateStatus)
    }

    private func apply(entry: VisualSettingCatalogEntry, record: VisualSettingRecord) -> VisualSettingRecord {
        do {
            try preferenceOperator.writeAppliedValue(entry)
            let observation = try preferenceOperator.read(entry)
            guard observationMatchesApplied(observation, entry: entry) else {
                return rollbackAfterApplyFailure(entry: entry, record: record, message: "Fresh-read verification did not match the applied value.")
            }
            let outcome: VisualSettingOutcome = entry.refreshBehavior == .deferredComponentRefresh ? .appliedDeferred : .applied
            let note = entry.refreshBehavior == .deferredComponentRefresh ? "Applied; component refresh is deferred until its next natural relaunch." : nil
            return record.replacing(outcome: outcome, note: note, updatedAt: nowProvider())
        } catch {
            return rollbackAfterApplyFailure(entry: entry, record: record, message: "Apply failed: \(error.localizedDescription)")
        }
    }

    private func rollbackAfterApplyFailure(entry: VisualSettingCatalogEntry, record: VisualSettingRecord, message: String) -> VisualSettingRecord {
        do {
            if record.priorWasPresent, let prior = record.priorValue {
                try preferenceOperator.write(prior, for: entry)
                let verification = try preferenceOperator.read(entry)
                guard VisualRestoreDecision.observationsMatch(verification, .present(prior)) else {
                    throw CoordinatorError.verificationFailed
                }
            } else {
                try preferenceOperator.delete(entry)
                let verification = try preferenceOperator.read(entry)
                guard VisualRestoreDecision.observationsMatch(verification, .absent) else {
                    throw CoordinatorError.verificationFailed
                }
            }
            return record.replacing(outcome: .applyFailed, note: message + " Original value was restored.", updatedAt: nowProvider())
        } catch {
            return record.replacing(outcome: .recoveryRequired, note: message + " Isolated rollback failed: \(error.localizedDescription)", updatedAt: nowProvider())
        }
    }

    private func restoreSynchronously(reason: VisualPerformanceRestoreReason) -> VisualPerformanceStatusSnapshot {
        let active: VisualPerformanceSessionRecord
        do {
            guard let loaded = try stateStore.loadActive() else {
                if let completed = try stateStore.loadLastCompleted() {
                    return snapshot(from: completed, aggregateStatus: completed.aggregateStatus)
                }
                return emptySnapshot()
            }
            active = loaded
        } catch {
            return recoveryFailureSnapshot("Visual Performance restoration state could not be read: \(error.localizedDescription)")
        }

        var records = active.settings
        for index in records.indices {
            if isResolvedWithoutRestore(records[index].outcome) { continue }
            guard let entry = catalog[records[index].id] else {
                records[index] = records[index].replacing(outcome: .recoveryRequired, note: "The recorded setting is not present in the current allowlist.", updatedAt: nowProvider())
                continue
            }
            records[index] = restore(entry: entry, record: records[index], reason: reason)
            let interim = VisualPerformanceSessionRecord(sessionIdentifier: active.sessionIdentifier, requestingUID: active.requestingUID, startedAt: active.startedAt, completedAt: nil, settings: records, aggregateStatus: .restoring)
            try? stateStore.writeActive(interim)
        }

        let aggregate = VisualPerformanceAggregateStatus.completed(for: records)
        let completedAt = aggregate == .successful ? nowProvider() : nil
        let result = VisualPerformanceSessionRecord(sessionIdentifier: active.sessionIdentifier, requestingUID: active.requestingUID, startedAt: active.startedAt, completedAt: completedAt, settings: records, aggregateStatus: aggregate)

        if aggregate == .successful {
            do {
                try stateStore.complete(result)
            } catch {
                let failure = records.map { record -> VisualSettingRecord in
                    if record.outcome == .restored || record.outcome == .preservedManualChange || record.outcome == .notApplicable || record.outcome == .unsupported || record.outcome == .applyFailed {
                        return record
                    }
                    return record.replacing(outcome: .recoveryRequired, note: "Completed state could not be made durable: \(error.localizedDescription)", updatedAt: nowProvider())
                }
                let fallback = VisualPerformanceSessionRecord(sessionIdentifier: active.sessionIdentifier, requestingUID: active.requestingUID, startedAt: active.startedAt, completedAt: nil, settings: failure, aggregateStatus: .recoveryRequired)
                try? stateStore.writeActive(fallback)
                return snapshot(from: fallback, aggregateStatus: .recoveryRequired)
            }
        } else {
            try? stateStore.writeActive(result)
        }
        return snapshot(from: result, aggregateStatus: aggregate)
    }

    private func restore(entry: VisualSettingCatalogEntry, record: VisualSettingRecord, reason: VisualPerformanceRestoreReason) -> VisualSettingRecord {
        do {
            let current = try preferenceOperator.read(entry)
            switch VisualRestoreDecision.decide(record: record, current: current) {
            case .preserveManualChange:
                return record.replacing(outcome: .preservedManualChange, note: "Current value differs from CatalinaPerformance's applied value; the manual change was preserved.", updatedAt: nowProvider())
            case .cannotSafelyDecide(let explanation):
                return record.replacing(outcome: .recoveryRequired, note: explanation, updatedAt: nowProvider())
            case .restorePrior(let prior):
                try preferenceOperator.write(prior, for: entry)
                let verification = try preferenceOperator.read(entry)
                guard VisualRestoreDecision.observationsMatch(verification, .present(prior)) else { throw CoordinatorError.verificationFailed }
                return record.replacing(outcome: .restored, note: "Restored during \(reason.rawValue).", updatedAt: nowProvider())
            case .deletePreviouslyAbsent:
                try preferenceOperator.delete(entry)
                let verification = try preferenceOperator.read(entry)
                guard VisualRestoreDecision.observationsMatch(verification, .absent) else { throw CoordinatorError.verificationFailed }
                return record.replacing(outcome: .restored, note: "Removed the session-created key during \(reason.rawValue).", updatedAt: nowProvider())
            }
        } catch {
            return record.replacing(outcome: .restoreFailed, note: "Restore failed: \(error.localizedDescription)", updatedAt: nowProvider())
        }
    }

    private func makeRecord(entry: VisualSettingCatalogEntry, prior: VisualPreferenceObservation, outcome: VisualSettingOutcome, note: String?, date: Date) -> VisualSettingRecord {
        switch prior {
        case .absent, .unsupportedType:
            return VisualSettingRecord(id: entry.id, displayName: entry.displayName, priorWasPresent: false, priorValue: nil, appliedValue: entry.appliedValue, outcome: outcome, note: note, updatedAt: date)
        case .present(let value):
            return VisualSettingRecord(id: entry.id, displayName: entry.displayName, priorWasPresent: true, priorValue: value, appliedValue: entry.appliedValue, outcome: outcome, note: note, updatedAt: date)
        }
    }

    private func observationMatchesApplied(_ observation: VisualPreferenceObservation, entry: VisualSettingCatalogEntry) -> Bool {
        guard case .present(let value) = observation else { return false }
        if value.scalarType == entry.appliedValue.scalarType {
            return VisualRestoreDecision.valuesMatch(value, entry.appliedValue)
        }
        switch (value, entry.appliedValue) {
        case (.integer(let integer), .floatingPoint(let floating)):
            return VisualRestoreDecision.valuesMatch(.floatingPoint(Double(integer)), .floatingPoint(floating))
        case (.floatingPoint(let floating), .integer(let integer)):
            return VisualRestoreDecision.valuesMatch(.floatingPoint(floating), .floatingPoint(Double(integer)))
        default:
            return false
        }
    }

    private func isResolvedWithoutRestore(_ outcome: VisualSettingOutcome) -> Bool {
        switch outcome {
        case .restored, .preservedManualChange, .notApplicable, .unsupported, .applyFailed:
            return true
        default:
            return false
        }
    }

    private func snapshot(from record: VisualPerformanceSessionRecord, aggregateStatus: VisualPerformanceAggregateStatus) -> VisualPerformanceStatusSnapshot {
        return VisualPerformanceStatusSnapshot(sessionIdentifier: record.sessionIdentifier, aggregateStatus: aggregateStatus, settings: record.settings, updatedAt: nowProvider())
    }

    private func emptySnapshot() -> VisualPerformanceStatusSnapshot {
        return VisualPerformanceStatusSnapshot(sessionIdentifier: nil, aggregateStatus: .notConfigured, settings: [], updatedAt: nowProvider())
    }

    private func recoveryFailureSnapshot(_ message: String) -> VisualPerformanceStatusSnapshot {
        let date = nowProvider()
        let records = catalog.entries.map { entry in
            VisualSettingRecord(id: entry.id, displayName: entry.displayName, priorWasPresent: false, priorValue: nil, appliedValue: entry.appliedValue, outcome: .recoveryRequired, note: message, updatedAt: date)
        }
        return VisualPerformanceStatusSnapshot(sessionIdentifier: nil, aggregateStatus: .recoveryRequired, settings: records, updatedAt: date)
    }

    private func persistenceEquivalent(
        _ left: VisualPerformanceSessionRecord,
        _ right: VisualPerformanceSessionRecord
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        guard let leftData = try? encoder.encode(left),
              let rightData = try? encoder.encode(right) else {
            return false
        }
        return leftData == rightData
    }

    private func publish(_ snapshot: VisualPerformanceStatusSnapshot, completion: @escaping SnapshotHandler) {
        callbackQueue.async {
            self.onSnapshot?(snapshot)
            completion(snapshot)
        }
    }

    private enum CoordinatorError: Error {
        case verificationFailed
    }
}
