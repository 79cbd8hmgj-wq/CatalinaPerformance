import Foundation
import CatalinaPerformancePriorityCore

public struct PerformanceSubsystemPaths {
    public let systemStateDirectory: URL
    public let foregroundRuntimeDirectory: URL
    public let appPriorityStatusFile: URL

    public init(systemStateDirectory: URL, foregroundRuntimeDirectory: URL, appPriorityStatusFile: URL) {
        self.systemStateDirectory = systemStateDirectory
        self.foregroundRuntimeDirectory = foregroundRuntimeDirectory
        self.appPriorityStatusFile = appPriorityStatusFile
    }
}

public struct DashboardCommandEvidence: Equatable {
    public let identifier: String
    public let succeeded: Bool
    public let output: String

    public init(identifier: String, succeeded: Bool, output: String) {
        self.identifier = identifier
        self.succeeded = succeeded
        self.output = output
    }
}

public protocol PerformanceSubsystemEvidenceProviding {
    func activationStatuses(at date: Date) -> [PerformanceSubsystemStatus]
    func restorationStatuses(commandEvidence: [DashboardCommandEvidence], at date: Date) -> [PerformanceSubsystemStatus]
}

public final class PerformanceSubsystemEvidenceReader: PerformanceSubsystemEvidenceProviding {
    private let paths: PerformanceSubsystemPaths
    private let fileManager: FileManager

    public init(paths: PerformanceSubsystemPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func activationStatuses(at date: Date) -> [PerformanceSubsystemStatus] {
        let markerExists = fileManager.fileExists(atPath: paths.systemStateDirectory.appendingPathComponent("performance_mode_on").path)
        let actions = readText(paths.systemStateDirectory.appendingPathComponent("actions_taken.txt"))

        let spotlight = actionStatus(
            subsystem: .spotlight,
            actions: actions,
            exactAction: "Paused Spotlight indexing on the boot volume with mdutil -i off /.",
            markerExists: markerExists,
            at: date
        )
        let timeMachine = actionStatus(
            subsystem: .timeMachine,
            actions: actions,
            exactAction: "Paused Time Machine automatic backups with tmutil disable.",
            markerExists: markerExists,
            at: date
        )
        let power = actionStatus(
            subsystem: .powerSettings,
            actions: actions,
            prefix: "Changed pmset AC power settings:",
            markerExists: markerExists,
            at: date
        )
        let ui = activationUIStatus(at: date)
        let apps = activationApplicationsStatus(at: date)
        let priority = activationPriorityStatus(at: date)
        return [spotlight, timeMachine, power, ui, apps, priority]
    }

    public func restorationStatuses(commandEvidence: [DashboardCommandEvidence], at date: Date) -> [PerformanceSubsystemStatus] {
        let restoreText = readText(paths.systemStateDirectory.appendingPathComponent("restore_actions_taken.txt"))
        let anyCommandSucceeded = commandEvidence.contains(where: { $0.succeeded })
        let anyCommandFailed = commandEvidence.contains(where: { !$0.succeeded })

        let spotlight = restorationActionStatus(
            subsystem: .spotlight,
            restoreText: restoreText,
            successText: "Re-enabled Spotlight indexing on the boot volume with mdutil -i on /.",
            anyCommandSucceeded: anyCommandSucceeded,
            anyCommandFailed: anyCommandFailed,
            at: date
        )
        let timeMachine = restorationActionStatus(
            subsystem: .timeMachine,
            restoreText: restoreText,
            successText: "Re-enabled Time Machine automatic backups with tmutil enable.",
            anyCommandSucceeded: anyCommandSucceeded,
            anyCommandFailed: anyCommandFailed,
            at: date
        )
        let power = restorationPowerStatus(
            restoreText: restoreText,
            anyCommandSucceeded: anyCommandSucceeded,
            anyCommandFailed: anyCommandFailed,
            at: date
        )
        let ui = restorationUIStatus(anyCommandSucceeded: anyCommandSucceeded, anyCommandFailed: anyCommandFailed, at: date)
        let apps = restorationApplicationsStatus(anyCommandSucceeded: anyCommandSucceeded, anyCommandFailed: anyCommandFailed, at: date)
        let priority = restorationPriorityStatus(anyCommandSucceeded: anyCommandSucceeded, anyCommandFailed: anyCommandFailed, at: date)
        return [spotlight, timeMachine, power, ui, apps, priority]
    }

    private func actionStatus(
        subsystem: PerformanceSubsystem,
        actions: String?,
        exactAction: String? = nil,
        prefix: String? = nil,
        markerExists: Bool,
        at date: Date
    ) -> PerformanceSubsystemStatus {
        let lines = actions?.split(whereSeparator: { $0.isNewline }).map(String.init) ?? []
        let found: Bool
        if let exactAction = exactAction {
            found = lines.contains(exactAction)
        } else if let prefix = prefix {
            found = lines.contains(where: { $0.hasPrefix(prefix) })
        } else {
            found = false
        }
        if found {
            return status(subsystem, .applied, date, nil)
        }
        return markerExists
            ? status(subsystem, .pending, date, "Performance Mode is active but matching action evidence is missing.")
            : status(subsystem, .notConfigured, date, nil)
    }

    private func activationUIStatus(at date: Date) -> PerformanceSubsystemStatus {
        guard let rows = tsvRows(paths.foregroundRuntimeDirectory.appendingPathComponent("ui_preferences.tsv")), !rows.isEmpty else {
            return status(.uiResponsiveness, .notConfigured, date, nil)
        }
        let states = rows.compactMap { $0.count > 7 ? $0[7] : nil }
        let restored = states.filter { $0 == "restored" }.count
        if restored == 0 { return status(.uiResponsiveness, .applied, date, "\(rows.count) preference changes recorded") }
        if restored == states.count { return status(.uiResponsiveness, .notConfigured, date, "UI preferences are already restored.") }
        return status(.uiResponsiveness, .partiallyApplied, date, "Mixed applied and restored UI preference rows.")
    }

    private func activationApplicationsStatus(at date: Date) -> PerformanceSubsystemStatus {
        guard let rows = tsvRows(paths.foregroundRuntimeDirectory.appendingPathComponent("applications.tsv")), !rows.isEmpty else {
            return status(.temporarilyClosedApplications, .notConfigured, date, nil)
        }
        let closed = rows.filter { $0.count > 4 && $0[4] == "1" }.count
        guard closed > 0 else { return status(.temporarilyClosedApplications, .notConfigured, date, "No applications were confirmed closed.") }
        return status(.temporarilyClosedApplications, .applied, date, "\(closed) apps closed")
    }

    private func activationPriorityStatus(at date: Date) -> PerformanceSubsystemStatus {
        guard let priority = readPriorityStatus() else { return status(.appPriority, .notConfigured, date, nil) }
        switch priority.state {
        case .active, .activeWithSkipped:
            return status(.appPriority, .applied, date, "\(priority.boostedCount) processes confirmed")
        case .starting, .ready, .waitingForSelectedApp:
            return status(.appPriority, .pending, date, priority.message)
        case .restorePending:
            return status(.appPriority, .partiallyRestored, date, priority.message)
        case .restored:
            return status(.appPriority, .restored, date, priority.message)
        case .failed:
            return status(.appPriority, .failed, date, priority.message)
        case .disabled:
            return status(.appPriority, .notConfigured, date, priority.message)
        }
    }

    private func restorationActionStatus(
        subsystem: PerformanceSubsystem,
        restoreText: String?,
        successText: String,
        anyCommandSucceeded: Bool,
        anyCommandFailed: Bool,
        at date: Date
    ) -> PerformanceSubsystemStatus {
        let lines = restoreText?.split(whereSeparator: { $0.isNewline }).map(String.init) ?? []
        if lines.contains(where: { $0.hasPrefix("FAILED:") && $0.localizedCaseInsensitiveContains(keyword(for: subsystem)) }) {
            return status(subsystem, .failed, date, "Recorded restore failure.")
        }
        if anyCommandSucceeded && lines.contains(successText) {
            return status(subsystem, .restored, date, nil)
        }
        if anyCommandFailed {
            return status(subsystem, .unknown, date, "Restore command failed and matching state proof is absent.")
        }
        return status(subsystem, .unknown, date, "Matching restoration evidence is absent.")
    }

    private func restorationPowerStatus(restoreText: String?, anyCommandSucceeded: Bool, anyCommandFailed: Bool, at date: Date) -> PerformanceSubsystemStatus {
        let text = restoreText ?? ""
        if text.split(whereSeparator: { $0.isNewline }).contains(where: { $0.hasPrefix("FAILED:") && $0.localizedCaseInsensitiveContains("pmset") }) {
            return status(.powerSettings, .failed, date, "Recorded pmset restore failure.")
        }
        if anyCommandSucceeded && text.localizedCaseInsensitiveContains("Running: pmset -c") {
            return status(.powerSettings, .restored, date, nil)
        }
        return status(.powerSettings, .unknown, date, anyCommandFailed ? "Restore command failed without pmset proof." : "Matching restoration evidence is absent.")
    }

    private func restorationUIStatus(anyCommandSucceeded: Bool, anyCommandFailed: Bool, at date: Date) -> PerformanceSubsystemStatus {
        guard let rows = tsvRows(paths.foregroundRuntimeDirectory.appendingPathComponent("ui_preferences.tsv")), !rows.isEmpty else {
            return status(.uiResponsiveness, .notConfigured, date, nil)
        }
        let values = rows.compactMap { $0.count > 7 ? $0[7] : nil }
        let restored = values.filter { $0 == "restored" }.count
        let failed = values.filter { $0 == "failed" }.count
        if anyCommandSucceeded && restored == values.count { return status(.uiResponsiveness, .restored, date, "\(restored) preferences restored") }
        if restored > 0 { return status(.uiResponsiveness, .partiallyRestored, date, "\(restored) of \(values.count) preferences restored") }
        if failed == values.count || anyCommandFailed { return status(.uiResponsiveness, .failed, date, "UI restore failed.") }
        return status(.uiResponsiveness, .unknown, date, "UI restoration is not proven.")
    }

    private func restorationApplicationsStatus(anyCommandSucceeded: Bool, anyCommandFailed: Bool, at date: Date) -> PerformanceSubsystemStatus {
        guard let rows = tsvRows(paths.foregroundRuntimeDirectory.appendingPathComponent("applications.tsv")), !rows.isEmpty else {
            return status(.temporarilyClosedApplications, .notConfigured, date, nil)
        }
        let relaunchRows = rows.filter { $0.count > 6 && $0[5] == "1" }
        guard !relaunchRows.isEmpty else { return status(.temporarilyClosedApplications, .notConfigured, date, nil) }
        let restored = relaunchRows.filter { $0[6] == "success" || $0[6] == "already_running" }.count
        let failed = relaunchRows.filter { $0[6] == "failed" }.count
        if anyCommandSucceeded && restored == relaunchRows.count { return status(.temporarilyClosedApplications, .restored, date, "\(restored) apps reopened") }
        if restored > 0 { return status(.temporarilyClosedApplications, .partiallyRestored, date, "\(restored) of \(relaunchRows.count) apps reopened") }
        if failed == relaunchRows.count || anyCommandFailed { return status(.temporarilyClosedApplications, .failed, date, "Application relaunch failed.") }
        return status(.temporarilyClosedApplications, .unknown, date, "Application restoration is not proven.")
    }

    private func restorationPriorityStatus(anyCommandSucceeded: Bool, anyCommandFailed: Bool, at date: Date) -> PerformanceSubsystemStatus {
        guard let priority = readPriorityStatus() else { return status(.appPriority, .notConfigured, date, nil) }
        switch priority.state {
        case .restored:
            return anyCommandSucceeded ? status(.appPriority, .restored, date, priority.message) : status(.appPriority, .unknown, date, priority.message)
        case .restorePending:
            return status(.appPriority, .partiallyRestored, date, priority.message)
        case .failed:
            return status(.appPriority, .failed, date, priority.message)
        case .disabled:
            return status(.appPriority, .notConfigured, date, priority.message)
        default:
            return status(.appPriority, anyCommandFailed ? .unknown : .unknown, date, "Priority restoration is not proven.")
        }
    }

    private func readPriorityStatus() -> AppPriorityStatus? {
        guard !paths.appPriorityStatusFile.path.contains("/private/"),
              let data = try? Data(contentsOf: paths.appPriorityStatusFile),
              data.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(AppPriorityStatus.self, from: data)
    }

    private func readText(_ url: URL) -> String? {
        guard !url.path.contains("/private/") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func tsvRows(_ url: URL) -> [[String]]? {
        guard let text = readText(url) else { return nil }
        let lines = text.split(whereSeparator: { $0.isNewline }).dropFirst()
        return lines.map { line in line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    private func status(_ subsystem: PerformanceSubsystem, _ state: PerformanceSubsystemState, _ date: Date, _ note: String?) -> PerformanceSubsystemStatus {
        PerformanceSubsystemStatus(subsystem: subsystem, state: state, updatedAt: date, note: note)
    }

    private func keyword(for subsystem: PerformanceSubsystem) -> String {
        switch subsystem {
        case .spotlight: return "spotlight"
        case .timeMachine: return "time machine"
        case .powerSettings: return "pmset"
        case .uiResponsiveness: return "ui"
        case .temporarilyClosedApplications: return "application"
        case .appPriority: return "priority"
        }
    }
}
