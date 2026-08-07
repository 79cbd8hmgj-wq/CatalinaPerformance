#if canImport(AppKit)
import AppKit
import CatalinaPerformanceVisualPerformanceCore

final class VisualPerformancePanelController: NSObject {
    private let aggregateLabel = NSTextField(
        labelWithString: "Status: Not inspected yet"
    )
    private let countsLabel = NSTextField(
        wrappingLabelWithString: "No Visual Performance session evidence is available yet."
    )
    private let settingsStack = NSStackView()
    private let viewButton = NSButton(
        title: "View Current Visual Settings",
        target: nil,
        action: nil
    )
    private let retryButton = NSButton(
        title: "Retry Visual Restoration",
        target: nil,
        action: nil
    )

    var onViewCurrentSettings: (() -> Void)?
    var onRetryRestoration: (() -> Void)?

    override init() {
        super.init()
        viewButton.target = self
        viewButton.action = #selector(viewCurrentSettings)
        retryButton.target = self
        retryButton.action = #selector(retryRestoration)
        retryButton.isHidden = true
        retryButton.isEnabled = false
    }

    func makeSectionView() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Visual Performance")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = .labelColor

        let divider = NSBox()
        divider.boxType = .separator

        let explanation = NSTextField(
            wrappingLabelWithString: "Automatically active with Performance Mode. Safe reversible animation, motion, transparency, minimize-effect, and applicable Dock-response reductions are applied. Manual visual-setting changes made during the session are preserved when Performance Mode turns OFF. CatalinaPerformance does not change display resolution, color, drivers, hardware clocks, or unrelated accessibility settings."
        )
        explanation.maximumNumberOfLines = 0
        explanation.textColor = .secondaryLabelColor

        aggregateLabel.font = NSFont.systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .semibold
        )
        countsLabel.maximumNumberOfLines = 0
        countsLabel.textColor = .secondaryLabelColor

        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 5
        settingsStack.setContentHuggingPriority(.required, for: .vertical)
        settingsStack.setContentCompressionResistancePriority(
            .required,
            for: .vertical
        )
        settingsStack.addArrangedSubview(
            readOnlyRow(label: "Settings", value: "Waiting for session evidence")
        )

        let buttonRow = NSStackView(views: [viewButton, retryButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let header = NSStackView(views: [titleLabel, divider])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        let contentStack = NSStackView(views: [
            header,
            explanation,
            aggregateLabel,
            countsLabel,
            settingsStack,
            buttonRow
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(
            top: 14,
            left: 14,
            bottom: 14,
            right: 14
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentCompressionResistancePriority(
            .required,
            for: .vertical
        )

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
        boxContentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: boxContentView.leadingAnchor
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: boxContentView.trailingAnchor
            ),
            contentStack.topAnchor.constraint(equalTo: boxContentView.topAnchor),
            contentStack.bottomAnchor.constraint(
                equalTo: boxContentView.bottomAnchor
            ),
            divider.widthAnchor.constraint(
                equalTo: contentStack.widthAnchor,
                constant: -28
            )
        ])
        return box
    }

    func updateStatus(_ snapshot: VisualPerformanceStatusSnapshot) {
        aggregateLabel.stringValue = "Status: " + aggregateText(snapshot.aggregateStatus)
        let counts = statusCounts(snapshot.settings)
        countsLabel.stringValue = "Applied: \(counts.applied)  Deferred: \(counts.deferred)  Unsupported: \(counts.unsupported)  Not applicable: \(counts.notApplicable)  Manual changes preserved: \(counts.manual)  Failed/unresolved: \(counts.failed)"

        settingsStack.arrangedSubviews.forEach { view in
            settingsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if snapshot.settings.isEmpty {
            settingsStack.addArrangedSubview(
                readOnlyRow(label: "Settings", value: "No session evidence yet")
            )
        } else {
            for record in snapshot.settings {
                settingsStack.addArrangedSubview(
                    readOnlyRow(
                        label: record.displayName,
                        value: outcomeText(record.outcome),
                        note: record.note
                    )
                )
            }
        }
        retryButton.isHidden = !snapshot.hasUnresolvedRestoration
        retryButton.isEnabled = snapshot.hasUnresolvedRestoration
    }

    func setActionsEnabled(_ enabled: Bool) {
        viewButton.isEnabled = enabled
        retryButton.isEnabled = enabled && !retryButton.isHidden
    }

    func presentCurrentSettings(
        _ settings: [VisualCurrentSetting],
        from window: NSWindow?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Current Visual Settings"
        alert.informativeText = settings.map { setting in
            let value: String
            switch setting.observation {
            case .absent:
                value = "Absent"
            case .unsupportedType(let typeName):
                value = "Unavailable or unsupported (\(typeName))"
            case .present(let scalar):
                value = scalarText(scalar)
            }
            if let note = setting.note, !note.isEmpty {
                return "\(setting.displayName): \(value) — \(note)"
            }
            return "\(setting.displayName): \(value)"
        }.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func readOnlyRow(
        label: String,
        value: String,
        note: String? = nil
    ) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .medium
        )
        let valueField = NSTextField(labelWithString: value)
        valueField.textColor = .secondaryLabelColor
        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        if let note = note, !note.isEmpty {
            let noteField = NSTextField(wrappingLabelWithString: note)
            noteField.textColor = .tertiaryLabelColor
            noteField.maximumNumberOfLines = 0
            let wrapper = NSStackView(views: [row, noteField])
            wrapper.orientation = .vertical
            wrapper.alignment = .leading
            wrapper.spacing = 2
            return wrapper
        }
        return row
    }

    private func statusCounts(
        _ settings: [VisualSettingRecord]
    ) -> (
        applied: Int,
        deferred: Int,
        unsupported: Int,
        notApplicable: Int,
        manual: Int,
        failed: Int
    ) {
        var result = (0, 0, 0, 0, 0, 0)
        for record in settings {
            switch record.outcome {
            case .applied, .restored:
                result.0 += 1
            case .appliedDeferred:
                result.1 += 1
            case .unsupported:
                result.2 += 1
            case .notApplicable:
                result.3 += 1
            case .preservedManualChange:
                result.4 += 1
            case .applyFailed, .restoreFailed, .recoveryRequired:
                result.5 += 1
            case .pending:
                break
            }
        }
        return result
    }

    private func aggregateText(
        _ status: VisualPerformanceAggregateStatus
    ) -> String {
        switch status {
        case .notConfigured: return "Not configured"
        case .preparing: return "Preparing"
        case .applied: return "Applied"
        case .appliedWithLimitations: return "Applied with limitations"
        case .failed: return "Failed"
        case .restoring: return "Restoring"
        case .recoveryRequired: return "Recovery required"
        case .successful: return "Successful"
        case .partiallyRestored: return "Partially restored"
        }
    }

    private func outcomeText(_ outcome: VisualSettingOutcome) -> String {
        switch outcome {
        case .pending: return "Pending"
        case .applied: return "Applied"
        case .appliedDeferred: return "Applied — component refresh deferred"
        case .restored: return "Restored"
        case .preservedManualChange: return "Preserved manual change"
        case .notApplicable: return "Not applicable"
        case .unsupported: return "Unsupported"
        case .applyFailed: return "Apply failed"
        case .restoreFailed: return "Restore failed"
        case .recoveryRequired: return "Recovery required"
        }
    }

    private func scalarText(_ value: VisualScalarValue) -> String {
        switch value {
        case .boolean(let bool): return bool ? "true" : "false"
        case .integer(let integer): return String(integer)
        case .floatingPoint(let floating): return String(floating)
        case .string(let string): return string
        }
    }

    @objc private func viewCurrentSettings() {
        onViewCurrentSettings?()
    }

    @objc private func retryRestoration() {
        onRetryRestoration?()
    }
}
#endif
