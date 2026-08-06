import Foundation
import CatalinaPerformancePriorityCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum BackgroundServiceWorkerError: Error, Equatable, CustomStringConvertible {
    case unsupportedCategory(BackgroundServiceCategory)
    case invalidTarget(String)
    case identityChanged(Int32)
    case signalFailed(Int32)
    case launchctlFailed(String, Int32)
    case restoreVerificationFailed(String)

    public var description: String {
        switch self {
        case .unsupportedCategory(let category): return "Unsupported background service category: \(category.rawValue)"
        case .invalidTarget(let label): return "Invalid background service target: \(label)"
        case .identityChanged(let pid): return "Process identity changed before mutation: \(pid)"
        case .signalFailed(let pid): return "SIGTERM failed for process \(pid)"
        case .launchctlFailed(let label, let status): return "launchctl kickstart failed for \(label) (\(status))"
        case .restoreVerificationFailed(let label): return "Restored worker was not observed for \(label)"
        }
    }
}

public protocol BackgroundServiceSignalMutating {
    func terminate(pid: Int32) throws
}

public protocol BackgroundServiceLaunchctlRestoring {
    func kickstart(label: String, uid: UInt32) throws
}

public protocol BackgroundServiceSleeping {
    func sleep(seconds: TimeInterval)
}

public protocol BackgroundServiceWorkerControlling {
    func capture(category: BackgroundServiceCategory, uid: UInt32) throws -> [BackgroundServiceWorkerRecord]
    func suppress(category: BackgroundServiceCategory, records: [BackgroundServiceWorkerRecord], uid: UInt32) -> BackgroundServiceCategoryRecord
    func verifySuppressed(category: BackgroundServiceCategory, records: [BackgroundServiceWorkerRecord], uid: UInt32) -> BackgroundServiceCategoryRecord
    func restore(category: BackgroundServiceCategory, records: [BackgroundServiceWorkerRecord], uid: UInt32) -> BackgroundServiceCategoryRecord
}

public struct DarwinBackgroundServiceSignalMutator: BackgroundServiceSignalMutating {
    public init() {}
    public func terminate(pid: Int32) throws {
        #if os(Linux)
        let result = Glibc.kill(pid, SIGTERM)
        #else
        let result = Darwin.kill(pid, SIGTERM)
        #endif
        guard result == 0 else { throw BackgroundServiceWorkerError.signalFailed(pid) }
    }
}

public struct DarwinBackgroundServiceLaunchctlRestorer: BackgroundServiceLaunchctlRestoring {
    private let catalog: CatalinaBackgroundServiceCatalog
    public init(catalog: CatalinaBackgroundServiceCatalog = .current) { self.catalog = catalog }

    public func kickstart(label: String, uid: UInt32) throws {
        guard catalog.targets.contains(where: {
            $0.launchLabel == label && $0.mechanism == .verifiedUserProcessTermination
        }) else {
            throw BackgroundServiceWorkerError.invalidTarget(label)
        }
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(uid)/\(label)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackgroundServiceWorkerError.launchctlFailed(label, process.terminationStatus)
        }
        #else
        throw BackgroundServiceWorkerError.launchctlFailed(label, -1)
        #endif
    }
}

public struct ThreadBackgroundServiceSleeper: BackgroundServiceSleeping {
    public init() {}
    public func sleep(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}

public final class BackgroundServiceWorkerController: BackgroundServiceWorkerControlling {
    private let inspector: AppPriorityProcessInspecting
    private let signalMutator: BackgroundServiceSignalMutating
    private let launchctlRestorer: BackgroundServiceLaunchctlRestoring
    private let sleeper: BackgroundServiceSleeping
    private let catalog: CatalinaBackgroundServiceCatalog
    private let now: () -> Date

    public init(
        inspector: AppPriorityProcessInspecting,
        signalMutator: BackgroundServiceSignalMutating,
        launchctlRestorer: BackgroundServiceLaunchctlRestoring,
        sleeper: BackgroundServiceSleeping = ThreadBackgroundServiceSleeper(),
        catalog: CatalinaBackgroundServiceCatalog = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.inspector = inspector
        self.signalMutator = signalMutator
        self.launchctlRestorer = launchctlRestorer
        self.sleeper = sleeper
        self.catalog = catalog
        self.now = now
    }

    public func capture(category: BackgroundServiceCategory, uid: UInt32) throws -> [BackgroundServiceWorkerRecord] {
        if catalog.unsupportedCategories.contains(category) { return [] }
        let targets = catalog.workerTargets(for: category)
        if targets.isEmpty { return [] }
        let processes = try inspector.allProcesses()
        var records: [BackgroundServiceWorkerRecord] = []
        for target in targets {
            try BackgroundServiceProtectedPolicy.validate(target: target)
            let allowed = Set(target.allowedExecutablePaths.map { canonicalPath($0) })
            for process in processes where process.effectiveUID == uid && uid != 0 {
                guard allowed.contains(canonicalPath(process.executablePath)) else { continue }
                records.append(record(from: process, launchLabel: target.launchLabel))
            }
        }
        return records.sorted { lhs, rhs in
            if lhs.launchLabel == rhs.launchLabel { return lhs.pid < rhs.pid }
            return lhs.launchLabel < rhs.launchLabel
        }
    }

    public func suppress(category: BackgroundServiceCategory, records: [BackgroundServiceWorkerRecord], uid: UInt32) -> BackgroundServiceCategoryRecord {
        if records.isEmpty {
            return BackgroundServiceCategoryRecord(
                category: category,
                requested: true,
                state: .paused,
                note: "No matching worker was running; relaunch monitoring remains active.",
                workers: [],
                userResume: nil,
                updatedAt: now()
            )
        }
        var results: [BackgroundServiceWorkerRecord] = []
        var degraded = false
        for record in records {
            guard let target = validatedTarget(category: category, record: record) else {
                results.append(updated(record, errorMessage: BackgroundServiceWorkerError.invalidTarget(record.launchLabel).description))
                degraded = true
                continue
            }
            do {
                let current = try inspector.process(pid: record.pid)
                guard identity(record, matches: current, uid: uid, allowedPaths: target.allowedExecutablePaths) else {
                    throw BackgroundServiceWorkerError.identityChanged(record.pid)
                }
                try signalMutator.terminate(pid: record.pid)
                let exited = waitForExit(record: record, uid: uid, allowedPaths: target.allowedExecutablePaths)
                results.append(updated(
                    record,
                    didAttemptStop: true,
                    didConfirmStop: exited,
                    errorMessage: exited ? nil : "Worker did not exit after SIGTERM."
                ))
                if !exited { degraded = true }
            } catch AppPriorityProcessError.readFailed {
                results.append(record)
            } catch {
                results.append(updated(record, didAttemptStop: false, didConfirmStop: false, errorMessage: String(describing: error)))
                degraded = true
            }
        }
        return BackgroundServiceCategoryRecord(
            category: category,
            requested: true,
            state: degraded ? .degraded : .paused,
            note: degraded ? "One or more workers could not be safely suppressed." : "Verified workers paused.",
            workers: results,
            userResume: nil,
            updatedAt: now()
        )
    }

    public func verifySuppressed(category: BackgroundServiceCategory, records: [BackgroundServiceWorkerRecord], uid: UInt32) -> BackgroundServiceCategoryRecord {
        var degraded = false
        var results: [BackgroundServiceWorkerRecord] = []
        for record in records {
            guard let target = validatedTarget(category: category, record: record) else {
                degraded = true
                results.append(updated(record, errorMessage: "Target no longer validates."))
                continue
            }
            let running = matchingProcessExists(uid: uid, allowedPaths: target.allowedExecutablePaths)
            if running {
                degraded = true
                results.append(updated(record, errorMessage: "Worker relaunched while suppression remained active."))
            } else {
                results.append(record)
            }
        }
        return BackgroundServiceCategoryRecord(
            category: category,
            requested: true,
            state: degraded ? .degraded : .paused,
            note: degraded ? "A verified worker is running." : "Verified workers remain paused.",
            workers: results,
            userResume: nil,
            updatedAt: now()
        )
    }

    public func restore(category: BackgroundServiceCategory, records: [BackgroundServiceWorkerRecord], uid: UInt32) -> BackgroundServiceCategoryRecord {
        if records.isEmpty {
            return BackgroundServiceCategoryRecord(
                category: category,
                requested: true,
                state: .restored,
                note: "No captured worker required restoration.",
                workers: [],
                userResume: nil,
                updatedAt: now()
            )
        }
        var results: [BackgroundServiceWorkerRecord] = []
        var failed = false
        for record in records {
            guard record.wasRunningBeforeSuppression && record.didConfirmStop else {
                results.append(record)
                continue
            }
            guard let target = validatedTarget(category: category, record: record) else {
                results.append(updated(record, didAttemptRestore: true, errorMessage: "Restore target no longer validates."))
                failed = true
                continue
            }
            if matchingProcessExists(uid: uid, allowedPaths: target.allowedExecutablePaths) {
                results.append(updated(record, didAttemptRestore: false, didConfirmRestore: true, errorMessage: nil))
                continue
            }
            do {
                try launchctlRestorer.kickstart(label: target.launchLabel, uid: uid)
                let appeared = waitForPresence(uid: uid, allowedPaths: target.allowedExecutablePaths)
                results.append(updated(
                    record,
                    didAttemptRestore: true,
                    didConfirmRestore: appeared,
                    errorMessage: appeared ? nil : BackgroundServiceWorkerError.restoreVerificationFailed(target.launchLabel).description
                ))
                if !appeared { failed = true }
            } catch {
                results.append(updated(record, didAttemptRestore: true, didConfirmRestore: false, errorMessage: String(describing: error)))
                failed = true
            }
        }
        return BackgroundServiceCategoryRecord(
            category: category,
            requested: true,
            state: failed ? .restoreFailed : .restored,
            note: failed ? "One or more workers require restoration retry." : "Worker restoration verified.",
            workers: results,
            userResume: nil,
            updatedAt: now()
        )
    }

    private func validatedTarget(category: BackgroundServiceCategory, record: BackgroundServiceWorkerRecord) -> BackgroundServiceTarget? {
        guard let target = catalog.workerTargets(for: category).first(where: { $0.launchLabel == record.launchLabel }) else { return nil }
        guard (try? BackgroundServiceProtectedPolicy.validate(target: target)) != nil else { return nil }
        guard target.allowedExecutablePaths.map({ canonicalPath($0) }).contains(canonicalPath(record.executablePath)) else { return nil }
        return target
    }

    private func record(from process: AppPriorityProcessIdentity, launchLabel: String) -> BackgroundServiceWorkerRecord {
        return BackgroundServiceWorkerRecord(
            pid: process.pid,
            parentPID: process.parentPID,
            effectiveUID: process.effectiveUID,
            executablePath: canonicalPath(process.executablePath),
            processStartSeconds: UInt64(max(0, process.startSeconds)),
            processStartMicroseconds: UInt64(max(0, process.startMicroseconds)),
            launchLabel: launchLabel,
            wasRunningBeforeSuppression: true,
            didAttemptStop: false,
            didConfirmStop: false,
            didAttemptRestore: false,
            didConfirmRestore: false,
            errorMessage: nil
        )
    }

    private func identity(_ record: BackgroundServiceWorkerRecord, matches current: AppPriorityProcessIdentity, uid: UInt32, allowedPaths: [String]) -> Bool {
        return record.pid == current.pid &&
            record.effectiveUID == uid && current.effectiveUID == uid && uid != 0 &&
            canonicalPath(record.executablePath) == canonicalPath(current.executablePath) &&
            allowedPaths.map({ canonicalPath($0) }).contains(canonicalPath(current.executablePath)) &&
            record.processStartSeconds == UInt64(max(0, current.startSeconds)) &&
            record.processStartMicroseconds == UInt64(max(0, current.startMicroseconds))
    }

    private func waitForExit(record: BackgroundServiceWorkerRecord, uid: UInt32, allowedPaths: [String]) -> Bool {
        for _ in 0..<30 {
            do {
                let current = try inspector.process(pid: record.pid)
                if !identity(record, matches: current, uid: uid, allowedPaths: allowedPaths) { return true }
            } catch {
                return true
            }
            sleeper.sleep(seconds: 0.1)
        }
        return false
    }

    private func waitForPresence(uid: UInt32, allowedPaths: [String]) -> Bool {
        for _ in 0..<30 {
            if matchingProcessExists(uid: uid, allowedPaths: allowedPaths) { return true }
            sleeper.sleep(seconds: 0.1)
        }
        return false
    }

    private func matchingProcessExists(uid: UInt32, allowedPaths: [String]) -> Bool {
        let allowed = Set(allowedPaths.map { canonicalPath($0) })
        guard let processes = try? inspector.allProcesses() else { return false }
        return processes.contains { process in
            process.effectiveUID == uid && uid != 0 && allowed.contains(canonicalPath(process.executablePath))
        }
    }

    private func canonicalPath(_ path: String) -> String {
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func updated(
        _ record: BackgroundServiceWorkerRecord,
        didAttemptStop: Bool? = nil,
        didConfirmStop: Bool? = nil,
        didAttemptRestore: Bool? = nil,
        didConfirmRestore: Bool? = nil,
        errorMessage: String?? = nil
    ) -> BackgroundServiceWorkerRecord {
        return BackgroundServiceWorkerRecord(
            pid: record.pid,
            parentPID: record.parentPID,
            effectiveUID: record.effectiveUID,
            executablePath: record.executablePath,
            processStartSeconds: record.processStartSeconds,
            processStartMicroseconds: record.processStartMicroseconds,
            launchLabel: record.launchLabel,
            wasRunningBeforeSuppression: record.wasRunningBeforeSuppression,
            didAttemptStop: didAttemptStop ?? record.didAttemptStop,
            didConfirmStop: didConfirmStop ?? record.didConfirmStop,
            didAttemptRestore: didAttemptRestore ?? record.didAttemptRestore,
            didConfirmRestore: didConfirmRestore ?? record.didConfirmRestore,
            errorMessage: errorMessage ?? record.errorMessage
        )
    }
}
