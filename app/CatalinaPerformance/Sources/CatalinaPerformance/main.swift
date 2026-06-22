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

    func scriptCommand(for script: ScriptKind) -> String {
        let scriptURL = resolveScript(named: script.fileName)
        return (["/bin/sh", scriptURL.path] + script.arguments).joined(separator: " ")
    }

    func run(_ script: ScriptKind, completion: @escaping (ScriptResult) -> Void) {
        let scriptURL = resolveScript(named: script.fileName)
        let launchCommand = scriptCommand(for: script)
        guard scriptExists(at: scriptURL) else {
            completion(ScriptResult(command: launchCommand, output: missingScriptMessage(scriptURL), exitStatus: nil, timedOut: false, cancelled: false))
            return
        }

        if script.requiresAdministratorPrivileges {
            runWithAdministratorPrivileges(script, scriptURL: scriptURL, launchCommand: launchCommand, completion: completion)
        } else {
            runDirect(script, scriptURL: scriptURL, launchCommand: launchCommand, completion: completion)
        }
    }

    private func runDirect(_ script: ScriptKind, scriptURL: URL, launchCommand: String, completion: @escaping (ScriptResult) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path] + script.arguments
        finish(process, script: script, launchCommand: launchCommand, timeout: 60, completion: completion)
    }

    private func runWithAdministratorPrivileges(_ script: ScriptKind, scriptURL: URL, launchCommand: String, completion: @escaping (ScriptResult) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", administratorAppleScript(for: scriptURL, arguments: script.arguments)]
        finish(process, script: script, launchCommand: launchCommand, timeout: 300, completion: completion)
    }

    private func finish(_ process: Process, script: ScriptKind, launchCommand: String, timeout: TimeInterval, completion: @escaping (ScriptResult) -> Void) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var didFinish = false

        func complete(_ result: ScriptResult) {
            DispatchQueue.main.async {
                if didFinish { return }
                didFinish = true
                completion(result)
            }
        }

        do {
            try process.run()
        } catch {
            completion(ScriptResult(command: launchCommand, output: "Failed to start \(script.fileName): \(error.localizedDescription)", exitStatus: nil, timedOut: false, cancelled: false))
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                process.terminate()
                complete(ScriptResult(command: launchCommand, output: "Timed out after \(Int(timeout)) seconds. The script was stopped so the UI would not remain stuck.", exitStatus: nil, timedOut: true, cancelled: false))
            }
        }

        process.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let cancelled = script.requiresAdministratorPrivileges && process.terminationStatus != 0 && output.localizedCaseInsensitiveContains("User canceled")
            complete(ScriptResult(command: launchCommand, output: cancelled ? "Cancelled by user" : output, exitStatus: process.terminationStatus, timedOut: false, cancelled: cancelled))
        }
    }

    private func scriptExists(at scriptURL: URL) -> Bool {
        fileManager.isExecutableFile(atPath: scriptURL.path) || fileManager.fileExists(atPath: scriptURL.path)
    }

    private func missingScriptMessage(_ scriptURL: URL) -> String {
        "Script not found: \(scriptURL.path)\nSet CATALINA_PERFORMANCE_SCRIPTS_DIR to the repository scripts directory during development."
    }

    private func administratorAppleScript(for scriptURL: URL, arguments: [String]) -> String {
        let command = (["/bin/sh", scriptURL.path] + arguments).map(shellQuote).joined(separator: " ")
        return "do shell script \(appleScriptString(command)) with administrator privileges"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func performanceModeIsOn() -> Bool {
        fileManager.fileExists(atPath: performanceModeMarkerURL.path)
    }

    private var performanceModeMarkerURL: URL {
        repositoryRootURL.appendingPathComponent(".catalina_performance_state", isDirectory: true)
            .appendingPathComponent("performance_mode_on")
    }

    private var repositoryRootURL: URL {
        resolveScript(named: ScriptKind.status.fileName)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
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

struct ScriptResult {
    let command: String
    let output: String
    let exitStatus: Int32?
    let timedOut: Bool
    let cancelled: Bool

    var succeeded: Bool {
        exitStatus == 0 && !timedOut && !cancelled
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

    var requiresAdministratorPrivileges: Bool {
        switch self {
        case .performanceOn, .performanceOff, .emergencyRestore:
            return true
        case .status:
            return false
        }
    }
}

final class MainWindowController: NSWindowController {
    private let runner = ScriptRunner()
    private let statusLabel = NSTextField(labelWithString: "Status: Not refreshed yet.")
    private let modeStateLabel = NSTextField(labelWithString: "Performance Mode appears OFF.")
    private let modeSwitch = NSSwitch()
    private let outputTextView = NSTextView(frame: .zero)
    private let onButton = NSButton(title: "Run Performance ON", target: nil, action: nil)
    private let offButton = NSButton(title: "Run Performance OFF", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Emergency Restore", target: nil, action: nil)

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
        onButton.target = self
        onButton.action = #selector(runPerformanceOn)
        offButton.target = self
        offButton.action = #selector(runPerformanceOff)
        restoreButton.target = self
        restoreButton.action = #selector(runEmergencyRestore)
        let buttons = NSStackView(views: [refreshButton, onButton, offButton, restoreButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillProportionally

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        outputTextView.textColor = .textColor
        outputTextView.backgroundColor = .textBackgroundColor
        outputTextView.insertionPointColor = .textColor
        outputTextView.minSize = NSSize(width: 0, height: 0)
        outputTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputTextView.isVerticallyResizable = true
        outputTextView.isHorizontallyResizable = false
        outputTextView.autoresizingMask = [.width]
        outputTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        outputTextView.textContainer?.widthTracksTextView = true
        outputTextView.string = "Script output will appear here.\n"
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = outputTextView

        let layout = NSStackView(views: [title, switchRow, modeStateLabel, statusLabel, buttons, scrollView])
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

        updateModeControls()
    }

    @objc private func refreshStatus() {
        run(.status, status: "Refreshing status...")
    }

    @objc private func runPerformanceOn() {
        confirm(
            title: "Turn Performance Mode ON?",
            message: "This will run the reviewed performance_on.sh script using the macOS administrator authorization prompt. It records prior state before changes and does not implement fan control, cache deletion, SIP changes, kexts, undervolting, or experimental features."
        ) { [weak self] in
            self?.run(.performanceOn, status: "Performance Mode ON requested...")
        }
    }

    @objc private func runPerformanceOff() {
        run(.performanceOff, status: "Performance Mode OFF requested...")
    }

    @objc private func runEmergencyRestore() {
        confirm(
            title: "Run Emergency Restore?",
            message: "Emergency Restore is a fallback path for recoverable state. It calls emergency_restore.sh and will not delete caches, modify SIP, touch fan control, unload arbitrary services, install kexts, undervolt, or use experimental CPU/MSR changes."
        ) { [weak self] in
            self?.run(.emergencyRestore, status: "Emergency Restore requested...")
        }
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
        setRunButtonsEnabled(false)
        appendOutput("\n$ \(runner.scriptCommand(for: script))\n")
        runner.run(script) { [weak self] result in
            guard let self = self else { return }
            let output = result.output.isEmpty ? "(No output.)\n" : result.output
            self.appendOutput(output.hasSuffix("\n") ? output : output + "\n")

            if let exitStatus = result.exitStatus {
                self.appendOutput("[\(script.fileName) exited with status \(exitStatus)]\n")
                if result.cancelled {
                    self.statusLabel.stringValue = "Status: Cancelled by user."
                } else {
                    self.statusLabel.stringValue = result.succeeded
                        ? "Status: Success running \(script.fileName)."
                        : "Status: Failed running \(script.fileName) (exit \(exitStatus))."
                }
            } else {
                self.appendOutput(result.timedOut ? "[\(script.fileName) timed out]\n" : "[\(script.fileName) did not start]\n")
                self.statusLabel.stringValue = result.timedOut ? "Status: Timed out running \(script.fileName)." : "Status: Failed running \(script.fileName) before exit."
            }

            self.setRunButtonsEnabled(true)
            self.outputTextView.scrollToEndOfDocument(nil)
        }
    }

    private func updateModeControls() {
        let isOn = runner.performanceModeIsOn()
        modeSwitch.state = isOn ? .on : .off
        modeStateLabel.stringValue = "Performance Mode appears \(isOn ? "ON" : "OFF")."
        onButton.isEnabled = !isOn
        offButton.isEnabled = isOn
        restoreButton.isEnabled = true
    }

    private func setRunButtonsEnabled(_ enabled: Bool) {
        if enabled {
            updateModeControls()
        } else {
            onButton.isEnabled = false
            offButton.isEnabled = false
            restoreButton.isEnabled = false
        }
    }

    private func appendOutput(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: outputTextView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        outputTextView.textStorage?.append(NSAttributedString(string: text, attributes: attributes))
        outputTextView.needsDisplay = true
        outputTextView.scrollRangeToVisible(NSRange(location: outputTextView.string.count, length: 0))
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
