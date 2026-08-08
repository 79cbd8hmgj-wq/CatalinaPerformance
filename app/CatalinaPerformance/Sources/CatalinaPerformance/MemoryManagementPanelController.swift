import Foundation
import CatalinaPerformanceDashboardCore
import CatalinaPerformanceMemoryCore

#if canImport(AppKit)
import AppKit

final class MemoryManagementPanelController {
    private let stateLabel = NSTextField(wrappingLabelWithString: "Current state: Unavailable")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private var statusTimer: Timer?

    deinit {
        statusTimer?.invalidate()
    }

    func makeControls() -> [NSView] {
        let title = NSTextField(labelWithString: "Memory / Swap")
        title.font = NSFont.boldSystemFont(ofSize: 16)
        let divider = NSBox()
        divider.boxType = .separator
        let header = NSStackView(views: [title, divider])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        let explanation = secondaryLabel(
            "Read-only monitoring. CatalinaPerformance reports memory pressure, compression, swap, and paging activity but does not change process priority, I/O policy, applications, swap, or VM settings. Detailed metrics are available in Session Dashboard."
        )
        stateLabel.maximumNumberOfLines = 0
        noteLabel.maximumNumberOfLines = 0
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = NSFont.systemFont(ofSize: 11)
        noteLabel.isHidden = true
        divider.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        refreshFromPersistedSession()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshFromPersistedSession()
        }

        return [header, explanation, stateLabel, noteLabel]
    }

    func update(status: MemoryManagementStatusSnapshot?, performanceModeIsOn: Bool) {
        guard performanceModeIsOn else {
            stateLabel.stringValue = "Current state: Idle"
            noteLabel.stringValue = "Memory / Swap monitoring is read-only."
            noteLabel.isHidden = false
            return
        }

        guard let status = status else {
            stateLabel.stringValue = "Current state: Unavailable"
            noteLabel.stringValue = "Memory / Swap session telemetry is unavailable."
            noteLabel.isHidden = false
            return
        }

        stateLabel.stringValue = "Current state: \(pressureText(status.pressureState))"
        noteLabel.stringValue = status.note ?? "Memory / Swap monitoring is read-only."
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
}
#endif
