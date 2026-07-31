#if canImport(AppKit)
import AppKit
import CatalinaPerformanceCore
import CatalinaPerformancePriorityCore

final class ForegroundSessionPanelController: NSObject {
    static var preferencesFileURL: URL {
        return AdvancedPreferences.configDirectoryURL
            .appendingPathComponent("foreground_session", isDirectory: true)
            .appendingPathComponent("preferences.env")
    }

    private let defaults: UserDefaults
    private let applicationsStack = NSStackView()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "Session state has not been inspected yet.")
    private let selectedLabel = NSTextField(labelWithString: "0 selected eligible applications")
    private var actionButtons: [NSButton] = []
    private var applicationCheckboxes: [String: NSButton] = [:]
    private weak var applicationsScrollView: NSScrollView?
    private weak var applicationsDocumentView: FlippedDocumentView?

    var onDryRun: (() -> Void)?
    var onApply: (() -> Void)?
    var onRestore: (() -> Void)?
    var onViewState: (() -> Void)?
    var onPreferenceWriteFailure: ((String) -> Void)?
    var prioritySelectionProvider: (() -> (enabled: Bool, bundleIdentifier: String?))?
    var onConfigurationConflict: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        ForegroundSessionPreferences.registerDefaults(in: defaults)
    }

    func makeSectionView() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Foreground Performance Session")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = .labelColor

        let divider = NSBox()
        divider.boxType = .separator

        let explanation = NSTextField(wrappingLabelWithString: "Optional and disabled by default. When enabled, Performance Mode requests a normal quit from only the applications you explicitly select, then restores only applications confirmed closed by CatalinaPerformance. Terminal, iTerm, Finder, Dock, and critical system processes are permanently excluded. Save dialogs or an application's refusal can prevent closure; no force quit or PID persistence is used.")
        explanation.maximumNumberOfLines = 0
        explanation.textColor = .secondaryLabelColor

        let enableCheckbox = preferenceCheckbox(
            title: "Enable Foreground Performance Session with Performance Mode",
            key: ForegroundSessionPreferences.featureEnabledKey
        )
        let finderCheckbox = preferenceCheckbox(
            title: "Disable Finder animations temporarily",
            key: ForegroundSessionPreferences.disableFinderAnimationsKey
        )
        let dockCheckbox = preferenceCheckbox(
            title: "Shorten Dock animations temporarily",
            key: ForegroundSessionPreferences.shortenDockAnimationsKey
        )
        let windowCheckbox = preferenceCheckbox(
            title: "Disable general window animations temporarily",
            key: ForegroundSessionPreferences.disableWindowAnimationsKey
        )

        let refreshButton = NSButton(title: "Refresh Running Applications", target: self, action: #selector(refreshRunningApplications))
        let dryRunButton = NSButton(title: "Dry Run Session", target: self, action: #selector(runDryRun))
        let applyButton = NSButton(title: "Apply Session Now", target: self, action: #selector(applyNow))
        let restoreButton = NSButton(title: "Restore Session", target: self, action: #selector(restoreNow))
        let stateButton = NSButton(title: "View Session State", target: self, action: #selector(viewState))
        actionButtons = [refreshButton, dryRunButton, applyButton, restoreButton, stateButton]

        applicationsStack.orientation = .vertical
        applicationsStack.alignment = .leading
        applicationsStack.spacing = 5
        applicationsStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        applicationsStack.translatesAutoresizingMaskIntoConstraints = false
        applicationsStack.setContentHuggingPriority(.required, for: .vertical)
        applicationsStack.setContentCompressionResistancePriority(.required, for: .vertical)

        let appScrollView = NSScrollView()
        appScrollView.hasVerticalScroller = true
        appScrollView.hasHorizontalScroller = false
        appScrollView.autohidesScrollers = true
        appScrollView.borderType = .bezelBorder
        appScrollView.drawsBackground = true
        appScrollView.backgroundColor = .textBackgroundColor
        appScrollView.translatesAutoresizingMaskIntoConstraints = false

        let applicationsDocumentView = FlippedDocumentView(frame: .zero)
        applicationsDocumentView.translatesAutoresizingMaskIntoConstraints = true
        applicationsDocumentView.addSubview(applicationsStack)
        appScrollView.documentView = applicationsDocumentView
        applicationsScrollView = appScrollView
        self.applicationsDocumentView = applicationsDocumentView

        let listActionRow = NSStackView(views: [refreshButton, stateButton])
        listActionRow.orientation = .horizontal
        listActionRow.alignment = .centerY
        listActionRow.spacing = 8

        let sessionActionRow = NSStackView(views: [dryRunButton, applyButton, restoreButton])
        sessionActionRow.orientation = .horizontal
        sessionActionRow.alignment = .centerY
        sessionActionRow.spacing = 8

        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.textColor = .secondaryLabelColor
        selectedLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [titleLabel, divider])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        let contentStack = NSStackView(views: [
            header,
            explanation,
            enableCheckbox,
            NSTextField(labelWithString: "Eligible running applications:"),
            selectedLabel,
            appScrollView,
            finderCheckbox,
            dockCheckbox,
            windowCheckbox,
            listActionRow,
            sessionActionRow,
            summaryLabel
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentCompressionResistancePriority(.required, for: .vertical)

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 6
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .vertical)
        box.setContentCompressionResistancePriority(.required, for: .vertical)

        guard let boxContentView = box.contentView else {
            return box
        }
        boxContentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: boxContentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: boxContentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: boxContentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: boxContentView.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            appScrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
            appScrollView.heightAnchor.constraint(equalToConstant: 180),

            applicationsStack.leadingAnchor.constraint(equalTo: applicationsDocumentView.leadingAnchor),
            applicationsStack.trailingAnchor.constraint(equalTo: applicationsDocumentView.trailingAnchor),
            applicationsStack.topAnchor.constraint(equalTo: applicationsDocumentView.topAnchor)
        ])

        writePreferences()
        refreshRunningApplications()
        DispatchQueue.main.async { [weak self] in
            self?.updateApplicationListDocumentSize()
        }
        return box
    }

    func updateApplicationListDocumentSize() {
        guard
            let scrollView = applicationsScrollView,
            let documentView = applicationsDocumentView
        else {
            return
        }

        let viewportSize = scrollView.contentSize
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return
        }

        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: viewportSize.width,
            height: max(viewportSize.height, documentView.frame.height)
        )
        documentView.layoutSubtreeIfNeeded()

        let requiredHeight = max(viewportSize.height, ceil(applicationsStack.fittingSize.height))
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: viewportSize.width,
            height: requiredHeight
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func setActionsEnabled(_ enabled: Bool) {
        actionButtons.forEach { $0.isEnabled = enabled }
        applicationCheckboxes.values.forEach { $0.isEnabled = enabled }
    }

    func updateSummary(from output: String) {
        let summary = ForegroundSessionSummary.parse(output)
        let active = summary.sessionActive ? "active" : "inactive"
        summaryLabel.stringValue = "Session \(active): \(summary.selected) selected, \(summary.confirmedClosed) confirmed closed, \(summary.skipped) skipped, \(summary.pendingRelaunch) pending relaunch, \(summary.relaunchFailed) relaunch failures, \(summary.uiRestorePending) UI preferences pending restore."
    }

    @objc private func refreshRunningApplications() {
        applicationCheckboxes.removeAll()
        applicationsStack.arrangedSubviews.forEach { view in
            applicationsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let candidates = NSWorkspace.shared.runningApplications.compactMap { application -> ForegroundApplication? in
            guard let identifier = application.bundleIdentifier else { return nil }
            let displayName = application.localizedName ?? identifier
            return ForegroundApplication(
                displayName: displayName,
                bundleIdentifier: identifier,
                isRunning: !application.isTerminated,
                isRegularGUIApplication: application.activationPolicy == .regular
            )
        }
        let eligible = ForegroundApplicationFilter.eligibleApplications(from: candidates)
        let selected = Set(ForegroundSessionPreferences.load(from: defaults).safeSelectedBundleIdentifiers)

        eligible.forEach { application in
            addApplicationCheckbox(
                title: "\(application.displayName) — \(application.bundleIdentifier)",
                bundleIdentifier: application.bundleIdentifier,
                selected: selected.contains(application.bundleIdentifier)
            )
        }

        let runningIdentifiers = Set(eligible.map { $0.bundleIdentifier })
        let selectedButNotRunning = selected.subtracting(runningIdentifiers).sorted()
        selectedButNotRunning.forEach { identifier in
            addApplicationCheckbox(
                title: "\(identifier) — selected, not currently running",
                bundleIdentifier: identifier,
                selected: true
            )
        }

        if eligible.isEmpty && selectedButNotRunning.isEmpty {
            let emptyLabel = NSTextField(wrappingLabelWithString: "No eligible running GUI applications were found. Open an application, then refresh this list.")
            emptyLabel.textColor = .secondaryLabelColor
            applicationsStack.addArrangedSubview(emptyLabel)
        }
        updateSelectedLabel()
        DispatchQueue.main.async { [weak self] in
            self?.updateApplicationListDocumentSize()
        }
    }

    private func addApplicationCheckbox(title: String, bundleIdentifier: String, selected: Bool) {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(applicationSelectionChanged(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier(rawValue: bundleIdentifier)
        checkbox.state = selected ? .on : .off
        checkbox.toolTip = bundleIdentifier
        applicationCheckboxes[bundleIdentifier] = checkbox
        applicationsStack.addArrangedSubview(checkbox)
    }

    private func preferenceCheckbox(title: String, key: String) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(preferenceChanged(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier(rawValue: key)
        checkbox.state = defaults.bool(forKey: key) ? .on : .off
        return checkbox
    }

    @objc private func preferenceChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        defaults.set(sender.state == .on, forKey: key)
        writePreferences()
    }

    @objc private func applicationSelectionChanged(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        var selected = Set(defaults.stringArray(forKey: ForegroundSessionPreferences.selectedBundleIdentifiersKey) ?? [])
        if sender.state == .on {
            if let priority = prioritySelectionProvider?(),
               AppPriorityConfigurationConflict.validateForegroundAddition(
                   bundleIdentifier: identifier,
                   priorityEnabled: priority.enabled,
                   priorityBundleIdentifier: priority.bundleIdentifier
               ) != nil {
                sender.state = .off
                onConfigurationConflict?("This app cannot be both closed and priority-boosted during the same Performance Mode session.")
                return
            }
            selected.insert(identifier)
        } else {
            selected.remove(identifier)
        }
        defaults.set(Array(selected).sorted(), forKey: ForegroundSessionPreferences.selectedBundleIdentifiersKey)
        writePreferences()
        updateSelectedLabel()
    }

    private func updateSelectedLabel() {
        let count = ForegroundSessionPreferences.load(from: defaults).safeSelectedBundleIdentifiers.count
        selectedLabel.stringValue = "\(count) selected eligible application\(count == 1 ? "" : "s")"
    }

    private func writePreferences() {
        do {
            try ForegroundSessionPreferences.load(from: defaults).write(to: Self.preferencesFileURL)
        } catch {
            onPreferenceWriteFailure?("Unable to write Foreground Session preferences to \(Self.preferencesFileURL.path): \(error.localizedDescription)")
        }
    }

    @objc private func runDryRun() {
        writePreferences()
        onDryRun?()
    }

    @objc private func applyNow() {
        writePreferences()
        onApply?()
    }

    @objc private func restoreNow() {
        onRestore?()
    }

    @objc private func viewState() {
        onViewState?()
    }
}
#endif
