import Foundation
import CatalinaPerformancePriorityCore

#if canImport(AppKit)
import AppKit
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class AppPriorityPanelController: NSObject {
    static var preferencesFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CatalinaPerformance/app_priority", isDirectory: true)
            .appendingPathComponent("selection.json")
    }

    static var statusFileURL: URL {
        URL(fileURLWithPath: "/var/run/CatalinaPerformance", isDirectory: true)
            .appendingPathComponent(String(getuid()), isDirectory: true)
            .appendingPathComponent("app_priority/status.json")
    }

    var onRunReport: (() -> Void)?
    var onPreferenceWriteFailure: ((String) -> Void)?
    var foregroundBundleIdentifiersProvider: (() -> Set<String>)?

    private let defaults: UserDefaults
    private let enableCheckbox = NSButton(checkboxWithTitle: "Boost one selected app while Performance Mode is ON", target: nil, action: nil)
    private let applicationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "Refresh Running Apps", target: nil, action: nil)
    private let reportButton = NSButton(title: "Run App Priority Report", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "Ready for Performance Mode")
    private var statusTimer: Timer?
    private var actionsEnabled = true
    private var performanceModeIsOn = false
    private var lastPersistedSelection: AppPrioritySelection

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        AppPriorityPreferences.registerDefaults(in: defaults)
        self.lastPersistedSelection = AppPriorityPreferences.load(from: defaults)
        super.init()
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enabledChanged)
        applicationPopup.target = self
        applicationPopup.action = #selector(applicationChanged)
        refreshButton.target = self
        refreshButton.action = #selector(refreshRunningApplications)
        reportButton.target = self
        reportButton.action = #selector(runReport)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.textColor = .secondaryLabelColor
    }

    deinit {
        statusTimer?.invalidate()
    }

    func makeSectionView() -> NSView {
        let title = NSTextField(labelWithString: "App Priority")
        title.font = NSFont.boldSystemFont(ofSize: 16)
        let divider = NSBox()
        divider.boxType = .separator
        let header = NSStackView(views: [title, divider])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        let explanation = NSTextField(wrappingLabelWithString: "While Performance Mode is ON, CatalinaPerformance gives one selected app and its verified same-user helper processes a modest CPU scheduling advantage at nice -5. The original nice values are recorded and restored when Performance Mode turns OFF or Emergency Restore runs.")
        explanation.maximumNumberOfLines = 0
        explanation.textColor = .secondaryLabelColor

        let appLabel = NSTextField(labelWithString: "Selected app:")
        let appRow = NSStackView(views: [appLabel, applicationPopup, refreshButton])
        appRow.orientation = .horizontal
        appRow.alignment = .centerY
        appRow.spacing = 8
        applicationPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let targetLabel = NSTextField(labelWithString: "Target priority: Nice -5")
        targetLabel.textColor = .secondaryLabelColor

        let content = NSStackView(views: [header, explanation, enableCheckbox, appRow, targetLabel, statusLabel, reportButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.required, for: .vertical)
        content.setContentCompressionResistancePriority(.required, for: .vertical)

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 6
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .vertical)
        box.setContentCompressionResistancePriority(.required, for: .vertical)
        guard let boxContentView = box.contentView else { return box }
        boxContentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: boxContentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: boxContentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: boxContentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: boxContentView.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            applicationPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        enableCheckbox.state = lastPersistedSelection.enabled ? .on : .off
        refreshRunningApplications()
        writeSelection(lastPersistedSelection, showError: true)
        startStatusPolling()
        updateInteractionState()
        return box
    }

    func currentSelection() -> AppPrioritySelection {
        return AppPriorityPreferences.load(from: defaults)
    }

    func setInteractionState(actionsEnabled: Bool, performanceModeIsOn: Bool) {
        self.actionsEnabled = actionsEnabled
        self.performanceModeIsOn = performanceModeIsOn
        updateInteractionState()
        refreshStatus()
    }

    private func updateInteractionState() {
        let configurationEnabled = actionsEnabled && !performanceModeIsOn
        enableCheckbox.isEnabled = configurationEnabled
        applicationPopup.isEnabled = configurationEnabled
        refreshButton.isEnabled = configurationEnabled
        reportButton.isEnabled = actionsEnabled
    }

    @objc private func refreshRunningApplications() {
        let saved = AppPriorityPreferences.load(from: defaults).application
        let running = NSWorkspace.shared.runningApplications.compactMap { runningApplication -> AppPriorityApplication? in
            guard runningApplication.activationPolicy == .regular,
                  !runningApplication.isTerminated,
                  let bundleIdentifier = runningApplication.bundleIdentifier,
                  !bundleIdentifier.isEmpty,
                  let bundleURL = runningApplication.bundleURL,
                  let executableURL = runningApplication.executableURL else { return nil }
            let displayName = runningApplication.localizedName ?? bundleIdentifier
            guard !AppPriorityApplicationFilter.isExcluded(bundleIdentifier: bundleIdentifier, displayName: displayName) else { return nil }
            return AppPriorityApplication(
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                bundlePath: bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
                executablePath: executableURL.resolvingSymlinksInPath().standardizedFileURL.path
            )
        }

        var byIdentifier: [String: AppPriorityApplication] = [:]
        running.forEach { byIdentifier[$0.bundleIdentifier] = $0 }
        applicationPopup.removeAllItems()
        applicationPopup.addItem(withTitle: "No app selected")
        applicationPopup.lastItem?.representedObject = nil

        byIdentifier.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }.forEach { application in
            addPopupItem(application: application, title: "\(application.displayName) — \(application.bundleIdentifier)")
        }

        if let saved = saved, byIdentifier[saved.bundleIdentifier] == nil {
            addPopupItem(application: saved, title: "\(saved.displayName) — selected, not currently running")
        }
        selectApplication(saved)
    }

    private func addPopupItem(application: AppPriorityApplication, title: String) {
        applicationPopup.addItem(withTitle: title)
        applicationPopup.lastItem?.representedObject = try? JSONEncoder().encode(application)
    }

    private func selectApplication(_ application: AppPriorityApplication?) {
        guard let application = application else {
            applicationPopup.selectItem(at: 0)
            return
        }
        for index in 0..<applicationPopup.numberOfItems {
            guard let candidate = applicationFromItem(applicationPopup.item(at: index)) else { continue }
            if candidate.bundleIdentifier == application.bundleIdentifier {
                applicationPopup.selectItem(at: index)
                return
            }
        }
        applicationPopup.selectItem(at: 0)
    }

    private func applicationFromItem(_ item: NSMenuItem?) -> AppPriorityApplication? {
        guard let data = item?.representedObject as? Data else { return nil }
        return try? JSONDecoder().decode(AppPriorityApplication.self, from: data)
    }

    @objc private func enabledChanged() {
        persistCandidate(enabled: enableCheckbox.state == .on, application: applicationFromItem(applicationPopup.selectedItem))
    }

    @objc private func applicationChanged() {
        persistCandidate(enabled: enableCheckbox.state == .on, application: applicationFromItem(applicationPopup.selectedItem))
    }

    private func persistCandidate(enabled: Bool, application: AppPriorityApplication?) {
        if enabled && application == nil {
            restoreControlsFromLastSelection()
            onPreferenceWriteFailure?("Choose an application before enabling App Priority.")
            return
        }
        if let conflict = AppPriorityConfigurationConflict.validate(
            priorityEnabled: enabled,
            priorityBundleIdentifier: application?.bundleIdentifier,
            foregroundBundleIdentifiers: foregroundBundleIdentifiersProvider?() ?? []
        ) {
            restoreControlsFromLastSelection()
            if case .conflict = conflict {
                let name = application?.displayName ?? application?.bundleIdentifier ?? "This app"
                onPreferenceWriteFailure?("\(name) cannot be both closed and priority-boosted during the same Performance Mode session.")
            }
            return
        }
        let candidate = AppPrioritySelection(enabled: enabled, application: application)
        do {
            try AppPriorityPreferences.save(candidate, to: defaults)
            try candidate.writeAtomically(to: Self.preferencesFileURL)
            lastPersistedSelection = candidate
            refreshStatus()
        } catch {
            restoreControlsFromLastSelection()
            onPreferenceWriteFailure?("Unable to save App Priority preferences: \(error.localizedDescription)")
        }
    }

    private func restoreControlsFromLastSelection() {
        enableCheckbox.state = lastPersistedSelection.enabled ? .on : .off
        selectApplication(lastPersistedSelection.application)
    }

    private func writeSelection(_ selection: AppPrioritySelection, showError: Bool) {
        do {
            try selection.writeAtomically(to: Self.preferencesFileURL)
        } catch where showError {
            onPreferenceWriteFailure?("Unable to write App Priority preferences to \(Self.preferencesFileURL.path): \(error.localizedDescription)")
        } catch {}
    }

    private func startStatusPolling() {
        statusTimer?.invalidate()
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func refreshStatus() {
        if let data = try? Data(contentsOf: Self.statusFileURL),
           let status = try? JSONDecoder().decode(AppPriorityStatus.self, from: data) {
            statusLabel.stringValue = statusText(status)
            return
        }
        let selection = AppPriorityPreferences.load(from: defaults)
        statusLabel.stringValue = selection.enabled ? "Ready for Performance Mode" : "Disabled"
    }

    private func statusText(_ status: AppPriorityStatus) -> String {
        switch status.state {
        case .disabled: return "Disabled"
        case .ready: return "Ready for Performance Mode"
        case .waitingForSelectedApp: return "Waiting for selected app"
        case .starting: return "Starting priority monitor…"
        case .active: return "Active — \(status.boostedCount) verified process\(status.boostedCount == 1 ? "" : "es") at nice -5"
        case .activeWithSkipped: return "Active — \(status.boostedCount) boosted, \(status.skippedCount) skipped"
        case .restorePending: return "Restore pending — \(status.boostedCount) process record\(status.boostedCount == 1 ? "" : "s")"
        case .restored: return "Restored"
        case .failed: return "Failed — \(status.message)"
        }
    }

    @objc private func runReport() {
        onRunReport?()
    }
}
#endif
