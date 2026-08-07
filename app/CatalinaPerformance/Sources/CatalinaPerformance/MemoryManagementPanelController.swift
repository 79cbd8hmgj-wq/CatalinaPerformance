import Foundation
import CatalinaPerformanceDashboardCore
import CatalinaPerformanceMemoryCore

#if canImport(AppKit)
import AppKit

final class MemoryManagementPanelController {
    private let stateLabel = NSTextField(wrappingLabelWithString: "Current state: Idle")
    private let interventionLabel = NSTextField(wrappingLabelWithString: "Automatic intervention: Ready when Performance Mode is ON")
    private let policyLabel = NSTextField(wrappingLabelWithString: "CPU deprioritization: nice +5")
    private let ioPolicyLabel = NSTextField(wrappingLabelWithString: "I/O deprioritization: Unsupported on this Catalina target")
    private let managedLabel = NSTextField(wrappingLabelWithString: "Maximum managed workloads: 3")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private var statusTimer: Timer?

    deinit {
        statusTimer?.invalidate()
    }

    func makeControls() -> [NSView] {
        let title = NSTextField(labelWithString: "Memory Pressure Management")
        title.font = NSFont.boldSystemFont(ofSize: 16)
        let divider = NSBox()
        divider.boxType = .separator
        let header = NSStackView(views: [title, divider])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        let explanation = secondaryLabel(
            "Automatically active with Performance Mode. CatalinaPerformance watches sustained VM contention and may temporarily deprioritize at most three verified background application families. Foreground apps, App Priority targets, CatalinaPerformance, AirDrop/networking, Bluetooth, audio, security infrastructure, root-owned processes, and unverifiable identities remain excluded."
        )
        for label in [stateLabel, interventionLabel, policyLabel, ioPolicyLabel, managedLabel, noteLabel] {
            label.maximumNumberOfLines = 0
        }
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = NSFont.systemFont(ofSize: 11)
        noteLabel.isHidden = true
        divider.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        refreshFromPersistedSession()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshFromPersistedSession()
        }

        return [header, explanation, stateLabel, interventionLabel, policyLabel, ioPolicyLabel, managedLabel, noteLabel]
    }

    func update(status: MemoryManagementStatusSnapshot?, performanceModeIsOn: Bool) {
        guard performanceModeIsOn else {
            stateLabel.stringValue = "Current state: Idle"
            interventionLabel.stringValue = "Automatic intervention: Ready when Performance Mode is ON"
            policyLabel.stringValue = "CPU deprioritization: nice +5 when sustained pressure is confirmed"
            ioPolicyLabel.stringValue = "I/O deprioritization: Unsupported on this Catalina target"
            managedLabel.stringValue = "Maximum managed workloads: 3"
            noteLabel.stringValue = ""
            noteLabel.isHidden = true
            return
        }

        guard let status = status else {
            stateLabel.stringValue = "Current state: Unavailable"
            interventionLabel.stringValue = "Automatic intervention: Unavailable"
            policyLabel.stringValue = "CPU deprioritization: nice +5 policy; no mutation occurs without valid telemetry and recovery state"
            ioPolicyLabel.stringValue = "I/O deprioritization: Unsupported on this Catalina target"
            managedLabel.stringValue = "Managed workloads: Unavailable (maximum 3)"
            noteLabel.stringValue = "Memory Management session telemetry is unavailable."
            noteLabel.isHidden = false
            return
        }

        stateLabel.stringValue = "Current state: \(pressureText(status.pressureState))"
        interventionLabel.stringValue = status.interventionActive
            ? "Automatic intervention: Deprioritizing \(status.managedFamilyCount) verified background workload\(status.managedFamilyCount == 1 ? "" : "s")"
            : "Automatic intervention: Monitoring"
        policyLabel.stringValue = "CPU deprioritization: nice +5 when active"
        ioPolicyLabel.stringValue = "I/O deprioritization: \(ioPolicyText(status.ioPolicyStatus))"
        managedLabel.stringValue = "Managed workloads: \(status.managedFamilyCount) / 3"
        noteLabel.stringValue = status.note ?? ""
        noteLabel.isHidden = noteLabel.stringValue.isEmpty
    }

    private func refreshFromPersistedSession() {
        precondition(Thread.isMainThread)
        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CatalinaPerformance", isDirectory: true)
        let performanceModeIsOn = FileManager.default.fileExists(
            atPath: applicationSupport
                .appendingPathComponent("system_state", isDirectory: true)
                .appendingPathComponent("performance_mode_on")
                .path
        )
        let store = PerformanceSessionStore(
            directoryURL: applicationSupport.appendingPathComponent("session_dashboard", isDirectory: true)
        )
        let status: MemoryManagementStatusSnapshot?
        switch store.loadActive() {
        case .loaded(let record):
            status = record.latest.memoryManagement
        case .missing, .recoveredInvalid:
            status = nil
        }
        update(status: status, performanceModeIsOn: performanceModeIsOn)
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        label.textColor = .secondaryLabelColor
        return label
    }

    private func pressureText(_ state: MemoryPressureState) -> String {
        switch state {
        case .healthy: return "Healthy"
        case .elevated: return "Elevated"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    private func ioPolicyText(_ status: MemoryIOPolicyStatus) -> String {
        switch status {
        case .unsupported: return "Unsupported on this Catalina target"
        case .available: return "Available"
        case .active: return "Active"
        }
    }
}
#endif
