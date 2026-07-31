import Foundation
import CatalinaPerformanceDashboardCore

#if canImport(AppKit)
import AppKit

final class SessionDashboardWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: PerformanceSessionCoordinator
    private let presenter: SessionDashboardPresenter
    private var observerToken: UUID?
    private var currentViewModel: SessionDashboardViewModel?
    private let scrollView = NSScrollView()
    private let documentView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 720, height: 640))
    private let contentStack = NSStackView()
    private let refreshButton = NSButton(title: "Refresh Now", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    var onRefreshNow: (() -> Void)?

    init(coordinator: PerformanceSessionCoordinator, presenter: SessionDashboardPresenter = SessionDashboardPresenter()) {
        self.coordinator = coordinator
        self.presenter = presenter
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Session Dashboard"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("CatalinaPerformance.SessionDashboard")
        super.init(window: window)
        window.delegate = self
        buildWindow()
        onRefreshNow = { [weak coordinator] in coordinator?.refreshNow() }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func showWindow(_ sender: Any?) {
        ensureObserver()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func render(_ viewModel: SessionDashboardViewModel) {
        precondition(Thread.isMainThread)
        currentViewModel = viewModel
        rebuildContent(from: viewModel)
    }

    func windowWillClose(_ notification: Notification) {
        if let token = observerToken {
            coordinator.removeObserver(token)
            observerToken = nil
        }
    }

    @objc private func refreshNowPressed() {
        onRefreshNow?()
    }

    @objc private func closePressed() {
        window?.performClose(nil)
    }

    private func ensureObserver() {
        if observerToken == nil {
            observerToken = coordinator.addObserver { [weak self] state in
                guard let self = self else { return }
                self.render(self.presenter.makeViewModel(from: state))
            }
        }
        render(presenter.makeViewModel(from: coordinator.currentState()))
    }

    private func buildWindow() {
        guard let root = window?.contentView else { return }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        documentView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.spacing = 14
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setHuggingPriority(.defaultLow, for: .horizontal)
        documentView.addSubview(contentStack)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 22),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -22),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20)
        ])

        refreshButton.target = self
        refreshButton.action = #selector(refreshNowPressed)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
    }

    private func rebuildContent(from viewModel: SessionDashboardViewModel) {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let title = NSTextField(labelWithString: viewModel.title)
        title.font = NSFont.boldSystemFont(ofSize: 24)
        title.setAccessibilityLabel(viewModel.title)
        contentStack.addArrangedSubview(title)

        if let warning = viewModel.warningText, !warning.isEmpty {
            addFullWidthArrangedSubview(warningBanner(warning))
        }

        let status = NSTextField(wrappingLabelWithString: "Status: \(viewModel.statusText)")
        status.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        status.setAccessibilityLabel("Session status")
        status.setAccessibilityValueDescription(viewModel.statusText)
        contentStack.addArrangedSubview(status)

        var metadata: [String] = []
        if let duration = viewModel.durationText { metadata.append("Duration: \(duration)") }
        if let completed = viewModel.completionText { metadata.append("Completed: \(completed)") }
        if let restore = viewModel.restoreResultText { metadata.append("Restore result: \(restore)") }
        if let target = viewModel.priorityTargetText { metadata.append("Priority target: \(target)") }
        if let samples = viewModel.sampleCountText { metadata.append("Samples collected: \(samples)") }
        if !metadata.isEmpty {
            let meta = NSTextField(wrappingLabelWithString: metadata.joined(separator: "    "))
            meta.textColor = .secondaryLabelColor
            meta.setAccessibilityLabel(metadata.joined(separator: ", "))
            contentStack.addArrangedSubview(meta)
        }

        if viewModel.screenKind == .empty || viewModel.screenKind == .warning {
            let empty = NSTextField(wrappingLabelWithString: "Unavailable metrics are shown as Unavailable rather than zero. The Last Completed Session appears here after Performance Mode is turned off.")
            empty.textColor = .secondaryLabelColor
            contentStack.addArrangedSubview(empty)
        }

        if !viewModel.systemRows.isEmpty {
            addFullWidthArrangedSubview(section(title: "System", metricRows: viewModel.systemRows))
        }
        if !viewModel.selectedAppRows.isEmpty {
            addFullWidthArrangedSubview(section(title: "Selected App", metricRows: viewModel.selectedAppRows))
        }
        if !viewModel.completedRows.isEmpty {
            addFullWidthArrangedSubview(completedSection(title: "Last Completed Session", rows: viewModel.completedRows))
        }
        if !viewModel.subsystemRows.isEmpty {
            let heading = viewModel.screenKind == .completed || viewModel.screenKind == .interrupted ? "Restoration" : "Active Changes"
            addFullWidthArrangedSubview(section(title: heading, metricRows: viewModel.subsystemRows))
        }

        let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 4))
        contentStack.addArrangedSubview(spacer)

        refreshButton.isEnabled = viewModel.screenKind != .finalizing && !viewModel.statusText.localizedCaseInsensitiveContains("preparing")
        let buttons = NSStackView(views: [refreshButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        contentStack.addArrangedSubview(buttons)

        contentStack.layoutSubtreeIfNeeded()
        let fitting = contentStack.fittingSize
        documentView.setFrameSize(NSSize(width: max(scrollView.contentSize.width, fitting.width + 44), height: max(scrollView.contentSize.height, fitting.height + 40)))
    }

    private func addFullWidthArrangedSubview(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func warningBanner(_ message: String) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 6
        box.borderWidth = 1
        box.borderColor = .systemOrange
        box.fillColor = NSColor.systemOrange.withAlphaComponent(0.12)
        let label = NSTextField(wrappingLabelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityLabel("Dashboard warning")
        label.setAccessibilityValueDescription(message)
        box.contentView?.addSubview(label)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
                label.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
            ])
        }
        return box
    }

    private func section(title: String, metricRows: [SessionDashboardMetricRow]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 7
        stack.alignment = .leading
        let heading = NSTextField(labelWithString: title.uppercased())
        heading.font = NSFont.boldSystemFont(ofSize: 12)
        heading.textColor = .secondaryLabelColor
        stack.addArrangedSubview(heading)
        metricRows.forEach { row in
            let rowView = metricRow(row)
            stack.addArrangedSubview(rowView)
            rowView.translatesAutoresizingMaskIntoConstraints = false
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func metricRow(_ row: SessionDashboardMetricRow) -> NSView {
        let label = NSTextField(labelWithString: row.label)
        label.font = NSFont.systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let value = NSTextField(labelWithString: row.current)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        value.alignment = .right
        value.setAccessibilityLabel(row.label)
        value.setAccessibilityValueDescription(row.current)

        var horizontalViews: [NSView] = [label]
        if let fraction = row.progressFraction {
            let indicator = NSProgressIndicator()
            indicator.isIndeterminate = false
            indicator.minValue = 0
            indicator.maxValue = 1
            indicator.doubleValue = fraction
            indicator.controlSize = .small
            indicator.style = .bar
            indicator.setAccessibilityLabel(row.label)
            indicator.setAccessibilityValueDescription(row.accessibilityDescription)
            indicator.widthAnchor.constraint(equalToConstant: 130).isActive = true
            horizontalViews.append(indicator)
        }
        horizontalViews.append(value)
        let top = NSStackView(views: horizontalViews)
        top.orientation = .horizontal
        top.spacing = 10
        top.distribution = .fill
        value.widthAnchor.constraint(greaterThanOrEqualToConstant: 105).isActive = true

        if let secondary = row.secondary, !secondary.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: secondary)
            detail.textColor = .secondaryLabelColor
            detail.font = NSFont.systemFont(ofSize: 11)
            let wrapper = NSStackView(views: [top, detail])
            wrapper.orientation = .vertical
            wrapper.spacing = 2
            wrapper.alignment = .leading
            top.translatesAutoresizingMaskIntoConstraints = false
            detail.translatesAutoresizingMaskIntoConstraints = false
            top.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
            detail.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
            return wrapper
        }
        return top
    }

    private func completedSection(title: String, rows: [SessionDashboardCompletedRow]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        let heading = NSTextField(labelWithString: title.uppercased())
        heading.font = NSFont.boldSystemFont(ofSize: 12)
        heading.textColor = .secondaryLabelColor
        stack.addArrangedSubview(heading)

        let header = completedRowViews(label: "Metric", baseline: "Baseline", average: "Average", peak: "Peak", final: "Final", bold: true)
        stack.addArrangedSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rows.forEach { row in
            let rowView = completedRowViews(label: row.label, baseline: row.baseline, average: row.average, peak: row.peak, final: row.final ?? "Unavailable", bold: false)
            stack.addArrangedSubview(rowView)
            rowView.translatesAutoresizingMaskIntoConstraints = false
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func completedRowViews(label: String, baseline: String, average: String, peak: String, final: String, bold: Bool) -> NSView {
        let values = [label, baseline, average, peak, final].map { text -> NSTextField in
            let field = NSTextField(labelWithString: text)
            field.font = bold ? NSFont.boldSystemFont(ofSize: 11) : NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
            field.setAccessibilityLabel(text)
            return field
        }
        let row = NSStackView(views: values)
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        return row
    }
}
#endif
