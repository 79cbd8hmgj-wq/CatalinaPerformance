import Foundation

#if canImport(AppKit)
import AppKit

/// CatalinaPerformance's GUI is intentionally a thin shell around the scripts in
/// `scripts/`. System-changing behavior belongs in those reviewed scripts so the
/// app does not duplicate restore logic or drift from the documented safety model.
final class ScriptRunner {
    private let fileManager = FileManager.default
    private let explicitScriptsDirectory: URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let configured = environment["CATALINA_PERFORMANCE_SCRIPTS_DIR"], !configured.isEmpty {
            explicitScriptsDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            explicitScriptsDirectory = nil
        }
    }

    func run(_ script: ScriptKind, completion: @escaping (String) -> Void) {
        let scriptURL = resolveScript(named: script.fileName)
        guard fileManager.isExecutableFile(atPath: scriptURL.path) || fileManager.fileExists(atPath: scriptURL.path) else {
            completion("Script not found: \(scriptURL.path)\nSet CATALINA_PERFORMANCE_SCRIPTS_DIR to the repository scripts directory during development.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path] + script.arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            completion("Failed to start \(script.fileName): \(error.localizedDescription)")
            return
        }

        process.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let status = "\n[\(script.fileName) exited with status \(process.terminationStatus)]"
            DispatchQueue.main.async {
                completion(output + status)
            }
        }
    }

    private func resolveScript(named fileName: String) -> URL {
        if let explicitScriptsDirectory = explicitScriptsDirectory {
            return explicitScriptsDirectory.appendingPathComponent(fileName)
        }

        // Development fallback: resolve from the Swift package directory back to
        // the repository root, then into scripts/. Bundled app packaging can set
        // CATALINA_PERFORMANCE_SCRIPTS_DIR or add a future resource lookup here.
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let packageRelative = currentDirectory
            .appendingPathComponent("../../scripts", isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: packageRelative.path) {
            return packageRelative
        }

        return currentDirectory
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

enum ScriptKind {
    case status
    case performanceOn
    case performanceOff
    case emergencyRestore

    var fileName: String {
        switch self {
        case .status: return "status_report.sh"
        case .performanceOn: return "performance_on.sh"
        case .performanceOff: return "performance_off.sh"
        case .emergencyRestore: return "emergency_restore.sh"
        }
    }

    var arguments: [String] {
        switch self {
        case .performanceOn, .emergencyRestore:
            // The GUI provides the explicit warning/intent gate before invoking
            // these scripts, then passes --yes so script output can be captured
            // in the app instead of blocking on terminal input.
            return ["--yes"]
        case .status, .performanceOff:
            return []
        }
    }
}

final class MainWindowController: NSWindowController {
    private let runner = ScriptRunner()
    private let statusLabel = NSTextField(labelWithString: "Status: Not refreshed yet.")
    private let modeSwitch = NSSwitch()
    private let outputTextView = NSTextView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CatalinaPerformance"
        self.init(window: window)
        buildInterface()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "CatalinaPerformance")
        title.font = NSFont.boldSystemFont(ofSize: 28)

        let switchLabel = NSTextField(labelWithString: "Performance Mode ON/OFF")
        let switchRow = NSStackView(views: [switchLabel, modeSwitch])
        switchRow.orientation = .horizontal
        switchRow.spacing = 12
        switchRow.alignment = .centerY

        let refreshButton = NSButton(title: "Refresh Status", target: self, action: #selector(refreshStatus))
        let onButton = NSButton(title: "Run Performance ON", target: self, action: #selector(runPerformanceOn))
        let offButton = NSButton(title: "Run Performance OFF", target: self, action: #selector(runPerformanceOff))
        let restoreButton = NSButton(title: "Emergency Restore", target: self, action: #selector(runEmergencyRestore))
        let advancedButton = NSButton(title: "Advanced", target: self, action: #selector(showAdvancedPlaceholder))

        let buttons = NSStackView(views: [refreshButton, onButton, offButton, restoreButton, advancedButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillProportionally

        outputTextView.isEditable = false
        outputTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        outputTextView.string = "Script output will appear here.\n"
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = outputTextView

        let advancedPlaceholder = NSTextField(labelWithString: "Advanced options are not implemented yet.")
        advancedPlaceholder.textColor = .secondaryLabelColor

        let layout = NSStackView(views: [title, switchRow, statusLabel, buttons, scrollView, advancedPlaceholder])
        layout.orientation = .vertical
        layout.spacing = 14
        layout.alignment = .leading
        layout.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(layout)

        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            layout.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            layout.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            scrollView.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
    }

    @objc private func refreshStatus() {
        run(.status, status: "Refreshing status...")
    }

    @objc private func runPerformanceOn() {
        confirm(
            title: "Turn Performance Mode ON?",
            message: "This will run the reviewed performance_on.sh script. It may ask macOS for administrator authorization through sudo, records prior state before changes, and does not implement fan control, cache deletion, SIP changes, kexts, undervolting, or experimental features."
        ) { [weak self] in
            self?.modeSwitch.state = .on
            self?.run(.performanceOn, status: "Performance Mode ON requested...")
        }
    }

    @objc private func runPerformanceOff() {
        modeSwitch.state = .off
        run(.performanceOff, status: "Performance Mode OFF requested...")
    }

    @objc private func runEmergencyRestore() {
        confirm(
            title: "Run Emergency Restore?",
            message: "Emergency Restore is a fallback path for recoverable state. It calls emergency_restore.sh and will not delete caches, modify SIP, touch fan control, unload arbitrary services, install kexts, undervolt, or use experimental CPU/MSR changes."
        ) { [weak self] in
            self?.modeSwitch.state = .off
            self?.run(.emergencyRestore, status: "Emergency Restore requested...")
        }
    }

    @objc private func showAdvancedPlaceholder() {
        appendOutput("\nAdvanced options are not implemented yet.\n")
    }

    private func confirm(title: String, message: String, then action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    private func run(_ script: ScriptKind, status: String) {
        statusLabel.stringValue = "Status: \(status)"
        appendOutput("\n$ \(script.fileName) \(script.arguments.joined(separator: " "))\n")
        runner.run(script) { [weak self] output in
            self?.appendOutput(output + "\n")
            self?.statusLabel.stringValue = "Status: Finished \(script.fileName)."
        }
    }

    private func appendOutput(_ text: String) {
        outputTextView.textStorage?.append(NSAttributedString(string: text))
        outputTextView.scrollToEndOfDocument(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
#else
print("CatalinaPerformance GUI requires macOS AppKit. Run this package on macOS Catalina or newer to launch the interface.")
#endif
