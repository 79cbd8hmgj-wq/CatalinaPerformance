#if canImport(AppKit)
import AppKit
import CatalinaPerformanceBackgroundServicesCore

final class BackgroundServiceSuppressionPanelController: NSObject {
    private let defaults: UserDefaults
    private let catalog: CatalinaBackgroundServiceCatalog
    private var categoryStatusLabels: [BackgroundServiceCategory: NSTextField] = [:]
    private var overallStatusLabel: NSTextField?
    private var iCloudDriveCheckbox: NSButton?
    private var actionsEnabled = true
    private var performanceModeIsOn = false

    var onPreferenceWriteFailure: ((String) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        catalog: CatalinaBackgroundServiceCatalog = .current
    ) {
        self.defaults = defaults
        self.catalog = catalog
        super.init()
    }

    func makeSectionView() -> NSView {
        let header = NSTextField(labelWithString: "Background Service Suppression")
        header.font = NSFont.boldSystemFont(ofSize: 16)
        header.textColor = .labelColor

        let divider = NSBox()
        divider.boxType = .separator

        let headerStack = NSStackView(views: [header, divider])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6

        let automaticTitle = NSTextField(labelWithString: "Automatic while Performance Mode is ON")
        automaticTitle.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.addArrangedSubview(headerStack)
        controls.addArrangedSubview(automaticTitle)
        controls.addArrangedSubview(makeCategoryRow(title: "macOS automatic updates", category: .softwareUpdate))
        controls.addArrangedSubview(makeCategoryRow(title: "App Store background updates", category: .appStoreUpdates))
        controls.addArrangedSubview(makeCategoryRow(title: "Photos background workers", category: .photos))
        controls.addArrangedSubview(makeCategoryRow(title: "Mail background workers", category: .mail))
        controls.addArrangedSubview(makeCategoryRow(title: "Messages and FaceTime workers", category: .messagesFaceTime))
        controls.addArrangedSubview(makeCategoryRow(title: "Siri, Dictation, and speech workers", category: .siriSpeech))

        let iCloudCheckbox = NSButton(
            checkboxWithTitle: "Pause iCloud Drive synchronization while Performance Mode is ON",
            target: self,
            action: #selector(saveICloudDrivePreference(_:))
        )
        iCloudCheckbox.state = defaults.bool(forKey: AdvancedPreferences.pauseICloudDriveKey) ? .on : .off
        iCloudCheckbox.toolTip = "Optional. This control remains unavailable unless the installed Catalina build has a verified, reversible iCloud Drive suppression target and resume path."
        self.iCloudDriveCheckbox = iCloudCheckbox
        controls.addArrangedSubview(iCloudCheckbox)
        controls.addArrangedSubview(makeCategoryStatusOnlyRow(category: .iCloudDrive))

        let protected = NSTextField(
            wrappingLabelWithString: "Protected: iCloud Keychain, Safari passwords, AirDrop, networking, diagnostics, crash reporting, and essential macOS services"
        )
        protected.maximumNumberOfLines = 0
        protected.textColor = .secondaryLabelColor
        controls.addArrangedSubview(protected)

        let overall = NSTextField(wrappingLabelWithString: "Status: Not configured")
        overall.maximumNumberOfLines = 0
        overall.textColor = .secondaryLabelColor
        self.overallStatusLabel = overall
        controls.addArrangedSubview(overall)

        controls.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        controls.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 6
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .vertical)
        box.setContentCompressionResistancePriority(.required, for: .vertical)

        guard let contentView = box.contentView else {
            return box
        }
        contentView.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controls.topAnchor.constraint(equalTo: contentView.topAnchor),
            controls.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -28)
        ])

        applyInitialAvailability()
        setInteractionState(actionsEnabled: actionsEnabled, performanceModeIsOn: performanceModeIsOn)
        return box
    }

    func setInteractionState(actionsEnabled: Bool, performanceModeIsOn: Bool) {
        self.actionsEnabled = actionsEnabled
        self.performanceModeIsOn = performanceModeIsOn
        let iCloudDriveSupported = !catalog.unsupportedCategories.contains(.iCloudDrive)
        let mayChangeICloudDrive = actionsEnabled && !performanceModeIsOn && iCloudDriveSupported
        iCloudDriveCheckbox?.isEnabled = mayChangeICloudDrive
    }

    func update(snapshot: BackgroundServiceStatusSnapshot) {
        overallStatusLabel?.stringValue = "Status: \(displayName(for: snapshot.state))"
        let byCategory = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.category, $0) })

        for category in BackgroundServiceCategory.allCases {
            guard let label = categoryStatusLabels[category] else { continue }
            if let status = byCategory[category] {
                label.stringValue = displayName(for: status)
            } else if catalog.unsupportedCategories.contains(category) {
                label.stringValue = "Unsupported on this Catalina build"
            } else {
                label.stringValue = "Not configured"
            }
        }
    }

    private func makeCategoryRow(title: String, category: BackgroundServiceCategory) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusLabel = makeStatusLabel(for: category)

        let row = NSStackView(views: [titleLabel, statusLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 12
        return row
    }

    private func makeCategoryStatusOnlyRow(category: BackgroundServiceCategory) -> NSView {
        let spacer = NSTextField(labelWithString: "")
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusLabel = makeStatusLabel(for: category)
        let row = NSStackView(views: [spacer, statusLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 12
        return row
    }

    private func makeStatusLabel(for category: BackgroundServiceCategory) -> NSTextField {
        let label = NSTextField(labelWithString: "Not configured")
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        categoryStatusLabels[category] = label
        return label
    }

    private func applyInitialAvailability() {
        for category in BackgroundServiceCategory.allCases {
            if catalog.unsupportedCategories.contains(category) {
                categoryStatusLabels[category]?.stringValue = "Unsupported on this Catalina build"
            }
        }
    }

    private func displayName(for overallState: BackgroundServiceOverallState) -> String {
        switch overallState {
        case .off: return "Off"
        case .preparing: return "Preparing"
        case .active: return "Active"
        case .degraded: return "Degraded"
        case .restoring: return "Restoring"
        case .recoveryRequired: return "Recovery required"
        case .restored: return "Restored"
        }
    }

    private func displayName(for status: BackgroundServiceCategoryStatus) -> String {
        switch status.state {
        case .notConfigured: return "Not configured"
        case .pending: return "Pending"
        case .unsupported: return "Unsupported"
        case .skipped: return status.note ?? "Skipped"
        case .capturing: return "Capturing state"
        case .suppressing: return "Pausing"
        case .paused: return "Paused"
        case .degraded: return status.note ?? "Degraded"
        case .resumedByUser:
            if let note = status.note, !note.isEmpty {
                return "Resumed — \(note)"
            }
            return "Resumed by user"
        case .restoring: return "Restoring"
        case .restored: return "Restored"
        case .restoreFailed: return status.note ?? "Restore failed"
        }
    }

    @objc private func saveICloudDrivePreference(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: AdvancedPreferences.pauseICloudDriveKey)
        let result = AdvancedPreferences.writeScriptConfig(defaults: defaults)
        if case .failure(let error) = result {
            onPreferenceWriteFailure?("Unable to save iCloud Drive preference: \(error.localizedDescription)")
        }
    }
}
#endif
