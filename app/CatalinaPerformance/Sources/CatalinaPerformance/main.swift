import Foundation
import CatalinaPerformanceCore
import CatalinaPerformancePriorityCore
import CatalinaPerformanceDashboardCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

#if canImport(AppKit)
import AppKit

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        return true
    }
}

/// CatalinaPerformance's GUI is intentionally a thin shell around the scripts in
/// `scripts/`. System-changing behavior belongs in those reviewed scripts so the
/// app does not duplicate restore logic or drift from the documented safety model.
final class ScriptRunner {
    private let fileManager = FileManager.default
    private let environment: [String: String]
    private let explicitScriptsDirectory: URL?
    private let explicitPriorityAgentURL: URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        if let configured = environment["CATALINA_PERFORMANCE_SCRIPTS_DIR"], !configured.isEmpty {
            explicitScriptsDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            explicitScriptsDirectory = nil
        }
        if let configured = environment["CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH"], !configured.isEmpty {
            explicitPriorityAgentURL = URL(fileURLWithPath: configured)
        } else {
            explicitPriorityAgentURL = nil
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
        var processEnvironment = environment
        scriptEnvironment().forEach { processEnvironment[$0.key] = $0.value }
        process.environment = processEnvironment
        finish(process, script: script, launchCommand: launchCommand, timeout: script.timeout, completion: completion)
    }

    private func runWithAdministratorPrivileges(_ script: ScriptKind, scriptURL: URL, launchCommand: String, completion: @escaping (ScriptResult) -> Void) {
        do {
            try fileManager.createDirectory(
                at: AdvancedPreferences.systemStateDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            completion(ScriptResult(
                command: launchCommand,
                output: "Unable to prepare the Performance Mode state directory: \(error.localizedDescription)",
                exitStatus: nil,
                timedOut: false,
                cancelled: false
            ))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", administratorAppleScript(for: scriptURL, arguments: script.arguments)]
        finish(process, script: script, launchCommand: launchCommand, timeout: script.timeout, completion: completion)
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
        let environment = scriptEnvironment()
        let assignments = environment.keys.sorted().map { key in
            key + "=" + shellQuote(environment[key] ?? "")
        }
        let command = assignments.joined(separator: " ") + " " +
            (["/bin/sh", scriptURL.path] + arguments).map(shellQuote).joined(separator: " ")
        return "do shell script \(appleScriptString(command)) with administrator privileges"
    }

    private func scriptEnvironment() -> [String: String] {
        return [
            "CATALINA_PERFORMANCE_PREFERENCES_FILE": AdvancedPreferences.configFileURL.path,
            "CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE": ForegroundSessionPanelController.preferencesFileURL.path,
            "CATALINA_PERFORMANCE_PRIORITY_SELECTION_FILE": AppPriorityPanelController.preferencesFileURL.path,
            "CATALINA_PERFORMANCE_STATE_DIR": AdvancedPreferences.systemStateDirectoryURL.path,
            "CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH": priorityAgentURL.path
        ]
    }

    private var priorityAgentURL: URL {
        if let explicitPriorityAgentURL = explicitPriorityAgentURL {
            return explicitPriorityAgentURL
        }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
            .appendingPathComponent("CatalinaPerformancePriorityAgent")
        if fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }

        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let packageBuild = currentDirectory
            .appendingPathComponent(".build/debug", isDirectory: true)
            .appendingPathComponent("CatalinaPerformancePriorityAgent")
            .standardizedFileURL
        if fileManager.fileExists(atPath: packageBuild.path) {
            return packageBuild
        }

        let repositoryBuild = currentDirectory
            .appendingPathComponent("app/CatalinaPerformance/.build/debug", isDirectory: true)
            .appendingPathComponent("CatalinaPerformancePriorityAgent")
            .standardizedFileURL
        if fileManager.fileExists(atPath: repositoryBuild.path) {
            return repositoryBuild
        }
        return bundled
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
        AdvancedPreferences.systemStateDirectoryURL.appendingPathComponent("performance_mode_on")
    }

    var repositoryRootURL: URL {
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

extension ScriptRunner: PerformanceModeStateProviding {}

struct AdvancedPreferences {
    static let pauseSpotlightKey = "advanced.pauseSpotlightWhileOn"
    static let pauseTimeMachineKey = "advanced.pauseTimeMachineWhileOn"
    static let preventSystemSleepKey = "advanced.preventPluggedInSystemSleepWhileOn"
    static let preventDisplaySleepKey = "advanced.preventDisplaySleepWhileOn"
    static let showSwapUsageWarningKey = "advanced.showSwapUsageWarning"
    static let showLowDiskSpaceWarningKey = "advanced.showLowDiskSpaceWarning"
    static let showMemoryPressureSummaryKey = "advanced.showMemoryPressureSummary"
    static let showTopMemoryProcessesKey = "advanced.showTopMemoryProcesses"
    static let configFileName = "advanced_preferences.env"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            pauseSpotlightKey: true,
            pauseTimeMachineKey: true,
            preventSystemSleepKey: true,
            preventDisplaySleepKey: true,
            showSwapUsageWarningKey: true,
            showLowDiskSpaceWarningKey: true,
            showMemoryPressureSummaryKey: true,
            showTopMemoryProcessesKey: true
        ])
    }

    static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CatalinaPerformance", isDirectory: true)
    }

    static var configFileURL: URL {
        configDirectoryURL.appendingPathComponent(configFileName)
    }

    static var systemStateDirectoryURL: URL {
        configDirectoryURL.appendingPathComponent("system_state", isDirectory: true)
    }

    @discardableResult
    static func writeScriptConfig(defaults: UserDefaults = .standard) -> Result<URL, Error> {
        let spotlight = defaults.bool(forKey: pauseSpotlightKey) ? "1" : "0"
        let timeMachine = defaults.bool(forKey: pauseTimeMachineKey) ? "1" : "0"
        let systemSleep = defaults.bool(forKey: preventSystemSleepKey) ? "1" : "0"
        let displaySleep = defaults.bool(forKey: preventDisplaySleepKey) ? "1" : "0"
        let swapWarning = defaults.bool(forKey: showSwapUsageWarningKey) ? "1" : "0"
        let diskWarning = defaults.bool(forKey: showLowDiskSpaceWarningKey) ? "1" : "0"
        let memoryPressure = defaults.bool(forKey: showMemoryPressureSummaryKey) ? "1" : "0"
        let topMemoryProcesses = defaults.bool(forKey: showTopMemoryProcessesKey) ? "1" : "0"
        let contents = "# CatalinaPerformance Advanced preferences.\n# Values are 1 for enabled and 0 for disabled. Missing or invalid values default to enabled in scripts.\nPAUSE_SPOTLIGHT_WHILE_ON=\(spotlight)\nPAUSE_TIME_MACHINE_WHILE_ON=\(timeMachine)\nPREVENT_SYSTEM_SLEEP_WHILE_ON=\(systemSleep)\nPREVENT_DISPLAY_SLEEP_WHILE_ON=\(displaySleep)\nSHOW_SWAP_USAGE_WARNING=\(swapWarning)\nSHOW_LOW_DISK_SPACE_WARNING=\(diskWarning)\nSHOW_MEMORY_PRESSURE_SUMMARY=\(memoryPressure)\nSHOW_TOP_MEMORY_PROCESSES=\(topMemoryProcesses)\n"

        do {
            try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
            try contents.write(to: configFileURL, atomically: true, encoding: .utf8)
            return .success(configFileURL)
        } catch {
            NSLog("Unable to write CatalinaPerformance script preferences: \(error.localizedDescription)")
            return .failure(error)
        }
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
    case memoryStorageReport
    case appPriorityReport
    case thermalFanReport
    case foregroundApply
    case foregroundApplyDryRun
    case foregroundRestore
    case foregroundRestoreDryRun
    case foregroundState
    case uiResponsivenessApply
    case uiResponsivenessApplyDryRun
    case uiResponsivenessRestore
    case uiResponsivenessRestoreDryRun

    init(sequenceScript: SequenceScript) {
        switch sequenceScript {
        case .performanceOn: self = .performanceOn
        case .performanceOff: self = .performanceOff
        case .foregroundApply: self = .foregroundApply
        case .foregroundApplyDryRun: self = .foregroundApplyDryRun
        case .foregroundRestore: self = .foregroundRestore
        case .foregroundRestoreDryRun: self = .foregroundRestoreDryRun
        case .foregroundState: self = .foregroundState
        case .uiApply: self = .uiResponsivenessApply
        case .uiApplyDryRun: self = .uiResponsivenessApplyDryRun
        case .uiRestore: self = .uiResponsivenessRestore
        case .uiRestoreDryRun: self = .uiResponsivenessRestoreDryRun
        }
    }

    var fileName: String {
        switch self {
        case .status: return "status_report.sh"
        case .performanceOn: return "performance_on_with_priority.sh"
        case .performanceOff: return "performance_off_with_priority.sh"
        case .emergencyRestore: return "emergency_restore_with_priority.sh"
        case .memoryStorageReport: return "memory_storage_report.sh"
        case .appPriorityReport: return "app_priority_report.sh"
        case .thermalFanReport: return "thermal_fan_report.sh"
        case .foregroundApply, .foregroundApplyDryRun: return "foreground_session_apply.sh"
        case .foregroundRestore, .foregroundRestoreDryRun: return "foreground_session_restore.sh"
        case .foregroundState: return "foreground_session_state.sh"
        case .uiResponsivenessApply, .uiResponsivenessApplyDryRun: return "ui_responsiveness_apply.sh"
        case .uiResponsivenessRestore, .uiResponsivenessRestoreDryRun: return "ui_responsiveness_restore.sh"
        }
    }

    var arguments: [String] {
        switch self {
        case .performanceOn, .emergencyRestore:
            return ["--requesting-uid", String(getuid()), "--yes"]
        case .performanceOff:
            return ["--requesting-uid", String(getuid())]
        case .foregroundApply, .foregroundRestore, .uiResponsivenessApply, .uiResponsivenessRestore:
            return ["--yes"]
        case .foregroundApplyDryRun, .foregroundRestoreDryRun, .uiResponsivenessApplyDryRun, .uiResponsivenessRestoreDryRun:
            return ["--dry-run"]
        case .status, .memoryStorageReport, .appPriorityReport, .thermalFanReport, .foregroundState:
            return []
        }
    }

    var requiresAdministratorPrivileges: Bool {
        switch self {
        case .performanceOn, .performanceOff, .emergencyRestore:
            return true
        case .status, .memoryStorageReport, .appPriorityReport, .thermalFanReport,
             .foregroundApply, .foregroundApplyDryRun, .foregroundRestore, .foregroundRestoreDryRun,
             .foregroundState, .uiResponsivenessApply, .uiResponsivenessApplyDryRun,
             .uiResponsivenessRestore, .uiResponsivenessRestoreDryRun:
            return false
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .performanceOn, .performanceOff, .emergencyRestore:
            return 300
        case .foregroundApply, .foregroundRestore:
            return 180
        default:
            return 60
        }
    }
}

final class AppScriptSequenceExecutor: SequenceScriptExecuting {
    private let runner: ScriptRunner

    init(runner: ScriptRunner) {
        self.runner = runner
    }

    func execute(_ script: SequenceScript, completion: @escaping (SequenceCommandResult) -> Void) {
        let kind = ScriptKind(sequenceScript: script)
        runner.run(kind) { result in
            completion(SequenceCommandResult(
                script: script,
                command: result.command,
                output: result.output,
                succeeded: result.succeeded
            ))
        }
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    let runner = ScriptRunner()
    private let statusLabel = NSTextField(labelWithString: "Status: Not refreshed yet.")
    private let modeStateLabel = NSTextField(labelWithString: "Performance Mode appears OFF.")
    private let modeSwitch = NSSwitch()
    private let outputTextView = NSTextView(frame: .zero)
    private let onButton = NSButton(title: "Run Performance ON", target: nil, action: nil)
    private let offButton = NSButton(title: "Run Performance OFF", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Emergency Restore", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh Status", target: nil, action: nil)
    private let advancedButton = NSButton(title: "Advanced", target: nil, action: nil)
    private let dashboardButton = NSButton(title: "View Session Dashboard", target: nil, action: nil)
    private var activeScriptCount = 0
    private var isDashboardTransitionInProgress = false
    private var advancedWindowController: AdvancedWindowController?
    private var sessionDashboardWindowController: SessionDashboardWindowController?
    private lazy var performanceSessionCoordinator: PerformanceSessionCoordinator = makePerformanceSessionCoordinator()
    private var activeSequenceCoordinator: ScriptSequenceCoordinator?
    private var activeSequenceExecutor: AppScriptSequenceExecutor?

    private var isScriptRunning: Bool {
        activeScriptCount > 0
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CatalinaPerformance"
        self.init(window: window)
        window.delegate = self
        buildInterface()
        isDashboardTransitionInProgress = true
        updateRunControls()
        performanceSessionCoordinator.recoverAtLaunch { [weak self] in
            guard let self = self else { return }
            self.isDashboardTransitionInProgress = false
            self.updateRunControls()
        }
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

        refreshButton.target = self
        refreshButton.action = #selector(refreshStatus)
        onButton.target = self
        onButton.action = #selector(runPerformanceOn)
        offButton.target = self
        offButton.action = #selector(runPerformanceOff)
        restoreButton.target = self
        restoreButton.action = #selector(runEmergencyRestore)
        advancedButton.target = self
        advancedButton.action = #selector(showAdvanced)
        dashboardButton.target = self
        dashboardButton.action = #selector(showSessionDashboard)
        let primaryButtons = NSStackView(views: [refreshButton, onButton, offButton, restoreButton])
        primaryButtons.orientation = .horizontal
        primaryButtons.spacing = 8
        primaryButtons.distribution = .fillProportionally

        let utilityButtons = NSStackView(views: [advancedButton, dashboardButton])
        utilityButtons.orientation = .horizontal
        utilityButtons.spacing = 8
        utilityButtons.distribution = .fill

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

        let layout = NSStackView(views: [title, switchRow, modeStateLabel, statusLabel, primaryButtons, utilityButtons, scrollView])
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
            message: "This will run the reviewed Performance Mode scripts using the macOS administrator authorization prompt. If App Priority is enabled, one temporary privileged monitor gives the selected app and verified helpers nice -5 for this session only. No persistent helper is installed. Turning Performance Mode OFF or running Emergency Restore attempts exact restoration of recorded priority values. Fan control, cache deletion, SIP changes, kexts, undervolting, and experimental features remain excluded."
        ) { [weak self] in
            guard let self = self, self.beginDashboardWrappedAction() else { return }
            let foregroundEnabled = ForegroundSessionPreferences.load().featureEnabled
            let prioritySelection = AppPriorityPreferences.load()
            let selectedApplication = prioritySelection.enabled ? prioritySelection.application : nil
            self.performanceSessionCoordinator.prepareForOn(selectedApplication: selectedApplication) { [weak self] in
                guard let self = self else { return }
                self.isDashboardTransitionInProgress = false
                self.runSequence(
                    PerformanceSequenceFactory.performanceOn(featureEnabled: foregroundEnabled),
                    status: "Performance Mode ON requested..."
                ) { [weak self] result in
                    self?.performanceSessionCoordinator.onSequenceCompleted(succeeded: result.succeeded)
                }
            }
        }
    }

    @objc private func runPerformanceOff() {
        // Restore scripts are intentionally attempted even when the feature is
        // currently disabled; they are safe no-ops when no session state exists.
        guard beginDashboardWrappedAction() else { return }
        performanceSessionCoordinator.prepareForFinalization(reason: .normalOff) { [weak self] in
            guard let self = self else { return }
            self.isDashboardTransitionInProgress = false
            self.runSequence(
                PerformanceSequenceFactory.performanceOff(featureEnabled: true),
                status: "Performance Mode OFF and foreground restoration requested..."
            ) { [weak self] result in
                guard let self = self else { return }
                let evidence = result.commandResults.map { command in
                    DashboardCommandEvidence(identifier: command.script.rawValue, succeeded: command.succeeded, output: command.output)
                }
                self.performanceSessionCoordinator.finalizationCompleted(commandEvidence: evidence, performanceModeStillOn: self.runner.performanceModeIsOn())
            }
        }
    }

    @objc private func runEmergencyRestore() {
        confirm(
            title: "Run Emergency Restore?",
            message: "Emergency Restore is a fallback path for recoverable state. It stops the temporary App Priority monitor and attempts exact restoration of recorded priority values before restoring normal Performance Mode state. It will not delete caches, modify SIP, touch fan control, unload arbitrary services, install kexts, undervolt, or use experimental CPU/MSR changes."
        ) { [weak self] in
            guard let self = self, self.beginDashboardWrappedAction() else { return }
            self.performanceSessionCoordinator.prepareForFinalization(reason: .emergencyRestore) { [weak self] in
                guard let self = self else { return }
                self.isDashboardTransitionInProgress = false
                self.run(.emergencyRestore, status: "Emergency Restore requested...") { [weak self] result in
                    guard let self = self else { return }
                    let evidence = DashboardCommandEvidence(identifier: "emergencyRestore", succeeded: result.succeeded, output: result.output)
                    self.performanceSessionCoordinator.finalizationCompleted(commandEvidence: [evidence], performanceModeStillOn: self.runner.performanceModeIsOn())
                }
            }
        }
    }

    @objc private func showSessionDashboard() {
        if sessionDashboardWindowController == nil {
            sessionDashboardWindowController = SessionDashboardWindowController(coordinator: performanceSessionCoordinator)
        }
        sessionDashboardWindowController?.showWindow(nil)
        sessionDashboardWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func makePerformanceSessionCoordinator() -> PerformanceSessionCoordinator {
        let user = ProcessDashboardCurrentUserProvider()
        let priorityStatusURL = URL(fileURLWithPath: "/var/run/CatalinaPerformance", isDirectory: true)
            .appendingPathComponent(String(user.uid), isDirectory: true)
            .appendingPathComponent("app_priority", isDirectory: true)
            .appendingPathComponent("status.json")
        let foregroundRuntimeURL = AdvancedPreferences.configDirectoryURL
            .appendingPathComponent("foreground_session", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        let collector = SessionMetricsCollector(
            nativeMetrics: DarwinDashboardNativeMetrics(),
            thermalProvider: PMSetThermalLimitProvider(),
            diskSpaceProvider: StartupVolumeDiskSpaceProvider(),
            selectionProvider: UserDefaultsAppPrioritySelectionProvider(),
            statusProvider: JSONAppPriorityStatusProvider(statusURL: priorityStatusURL),
            currentUserProvider: user,
            processInspector: DarwinAppPriorityProcessInspector()
        )
        let evidence = PerformanceSubsystemEvidenceReader(paths: PerformanceSubsystemPaths(
            systemStateDirectory: AdvancedPreferences.systemStateDirectoryURL,
            foregroundRuntimeDirectory: foregroundRuntimeURL,
            appPriorityStatusFile: priorityStatusURL
        ))
        return PerformanceSessionCoordinator(
            collector: collector,
            recorder: PerformanceSessionRecorder(),
            store: PerformanceSessionStore(directoryURL: AdvancedPreferences.configDirectoryURL.appendingPathComponent("session_dashboard", isDirectory: true)),
            evidenceProvider: evidence,
            modeStateProvider: runner,
            callbackQueue: .main
        )
    }

    private func beginDashboardWrappedAction() -> Bool {
        guard !isScriptRunning, !isDashboardTransitionInProgress else {
            statusLabel.stringValue = "Status: Another CatalinaPerformance action is already running."
            appendOutput("\nAnother CatalinaPerformance action is already running. Wait for it to finish before changing Performance Mode.\n")
            return false
        }
        isDashboardTransitionInProgress = true
        updateRunControls()
        return true
    }

    @objc private func showAdvanced() {
        if advancedWindowController == nil {
            advancedWindowController = AdvancedWindowController(
                onRunAppPriorityReport: { [weak self] in
                    self?.run(.appPriorityReport, status: "Running App Priority report...")
                },
                onRunMemoryStorageCheck: { [weak self] in
                    self?.run(.memoryStorageReport, status: "Running Memory / Storage check...")
                },
                onRunThermalFanCheck: { [weak self] in
                    self?.run(.thermalFanReport, status: "Running Thermal / Fan check...")
                },
                onForegroundDryRun: { [weak self] in
                    self?.runSequence(PerformanceSequenceFactory.manualDryRun(), status: "Running Foreground Session dry run...")
                },
                onForegroundApply: { [weak self] in
                    self?.confirm(
                        title: "Apply Foreground Performance Session?",
                        message: "Selected applications will receive normal quit requests. Unsaved-document prompts may appear, refusals are not forced, and only applications confirmed closed by CatalinaPerformance will later be relaunched."
                    ) { [weak self] in
                        self?.runSequence(PerformanceSequenceFactory.manualApply(), status: "Applying Foreground Performance Session...")
                    }
                },
                onForegroundRestore: { [weak self] in
                    self?.runSequence(PerformanceSequenceFactory.manualRestore(), status: "Restoring Foreground Performance Session...")
                },
                onForegroundViewState: { [weak self] in
                    self?.run(.foregroundState, status: "Reading Foreground Session state...")
                },
                onPreferenceWriteFailure: { [weak self] message in
                    self?.showPreferenceWriteFailure(message)
                }
            )
        }
        advancedWindowController?.setScriptActionsEnabled(!isScriptRunning, performanceModeIsOn: runner.performanceModeIsOn())
        advancedWindowController?.showWindow(nil)
        advancedWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func showPreferenceWriteFailure(_ message: String) {
        statusLabel.stringValue = "Status: Advanced preferences could not be saved."
        appendOutput("\n[Advanced preferences error] \(message)\n")
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

    private func run(_ script: ScriptKind, status: String, completion: ((ScriptResult) -> Void)? = nil) {
        guard !isScriptRunning else {
            statusLabel.stringValue = "Status: Another CatalinaPerformance action is already running."
            appendOutput("\nAnother CatalinaPerformance action is already running. Wait for the active script to finish before starting \(script.fileName).\n")
            outputTextView.scrollToEndOfDocument(nil)
            return
        }

        activeScriptCount += 1
        statusLabel.stringValue = "Status: \(status)"
        updateRunControls()
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

            if script.fileName == ScriptKind.foregroundState.fileName {
                self.advancedWindowController?.updateForegroundSummary(from: result.output)
            }
            self.activeScriptCount = max(0, self.activeScriptCount - 1)
            self.updateRunControls()
            self.outputTextView.scrollToEndOfDocument(nil)
            completion?(result)
        }
    }

    private func runSequence(
        _ steps: [ScriptSequenceStep],
        status: String,
        completion: ((ScriptSequenceResult) -> Void)? = nil
    ) {
        guard !isScriptRunning else {
            statusLabel.stringValue = "Status: Another CatalinaPerformance action is already running."
            appendOutput("\nAnother CatalinaPerformance action is already running. Wait for it to finish before starting this sequence.\n")
            return
        }

        activeScriptCount += 1
        statusLabel.stringValue = "Status: \(status)"
        updateRunControls()

        let executor = AppScriptSequenceExecutor(runner: runner)
        let coordinator = ScriptSequenceCoordinator(executor: executor)
        activeSequenceExecutor = executor
        activeSequenceCoordinator = coordinator

        coordinator.run(steps: steps) { [weak self] sequenceResult in
            guard let self = self else { return }
            sequenceResult.commandResults.forEach { result in
                self.appendOutput("\n$ \(result.command)\n")
                let output = result.output.isEmpty ? "(No output.)\n" : result.output
                self.appendOutput(output.hasSuffix("\n") ? output : output + "\n")
                self.appendOutput("[\(result.script.rawValue): \(result.succeeded ? "success" : "failed")]\n")
            }

            self.statusLabel.stringValue = sequenceResult.succeeded
                ? "Status: Sequence completed successfully."
                : "Status: Sequence completed with a failure; recorded rollback steps were attempted."
            self.activeSequenceCoordinator = nil
            self.activeSequenceExecutor = nil
            self.activeScriptCount = max(0, self.activeScriptCount - 1)
            self.updateRunControls()
            self.outputTextView.scrollToEndOfDocument(nil)
            completion?(sequenceResult)
        }
    }

    private func updateModeControls() {
        updateRunControls()
    }

    private func updateRunControls() {
        let isOn = runner.performanceModeIsOn()
        modeSwitch.state = isOn ? .on : .off
        modeStateLabel.stringValue = "Performance Mode appears \(isOn ? "ON" : "OFF")."

        let canStartScript = !isScriptRunning && !isDashboardTransitionInProgress
        refreshButton.isEnabled = canStartScript
        onButton.isEnabled = canStartScript && !isOn
        offButton.isEnabled = canStartScript && isOn
        restoreButton.isEnabled = canStartScript
        advancedButton.isEnabled = true
        dashboardButton.isEnabled = true
        advancedWindowController?.setScriptActionsEnabled(canStartScript, performanceModeIsOn: isOn)
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


final class AdvancedWindowController: NSWindowController, NSWindowDelegate {
    private let preferences = UserDefaults.standard
    private var memoryStorageButton: NSButton?
    private var appPriorityPanelController: AppPriorityPanelController?
    private var thermalFanButton: NSButton?
    private var foregroundPanelController: ForegroundSessionPanelController?
    private weak var advancedScrollView: NSScrollView?
    private weak var advancedDocumentView: FlippedDocumentView?
    private weak var advancedStack: NSStackView?
    private var onRunAppPriorityReport: (() -> Void)?
    private var onRunMemoryStorageCheck: (() -> Void)?
    private var onRunThermalFanCheck: (() -> Void)?
    private var onPreferenceWriteFailure: ((String) -> Void)?

    convenience init(
        onRunAppPriorityReport: (() -> Void)? = nil,
        onRunMemoryStorageCheck: (() -> Void)? = nil,
        onRunThermalFanCheck: (() -> Void)? = nil,
        onForegroundDryRun: (() -> Void)? = nil,
        onForegroundApply: (() -> Void)? = nil,
        onForegroundRestore: (() -> Void)? = nil,
        onForegroundViewState: (() -> Void)? = nil,
        onPreferenceWriteFailure: ((String) -> Void)? = nil
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CatalinaPerformance Advanced"
        self.init(window: window)
        self.onRunAppPriorityReport = onRunAppPriorityReport
        self.onRunMemoryStorageCheck = onRunMemoryStorageCheck
        self.onRunThermalFanCheck = onRunThermalFanCheck
        self.onPreferenceWriteFailure = onPreferenceWriteFailure
        let foregroundPanel = ForegroundSessionPanelController(defaults: preferences)
        foregroundPanel.onDryRun = onForegroundDryRun
        foregroundPanel.onApply = onForegroundApply
        foregroundPanel.onRestore = onForegroundRestore
        foregroundPanel.onViewState = onForegroundViewState
        foregroundPanel.onPreferenceWriteFailure = onPreferenceWriteFailure
        self.foregroundPanelController = foregroundPanel

        let priorityPanel = AppPriorityPanelController(defaults: preferences)
        priorityPanel.onRunReport = onRunAppPriorityReport
        priorityPanel.onPreferenceWriteFailure = onPreferenceWriteFailure
        priorityPanel.foregroundBundleIdentifiersProvider = {
            Set(ForegroundSessionPreferences.load(from: self.preferences).safeSelectedBundleIdentifiers)
        }
        foregroundPanel.prioritySelectionProvider = { [weak priorityPanel] in
            let selection = priorityPanel?.currentSelection() ?? AppPrioritySelection(enabled: false, application: nil)
            return (selection.enabled, selection.application?.bundleIdentifier)
        }
        foregroundPanel.onConfigurationConflict = onPreferenceWriteFailure
        self.appPriorityPanelController = priorityPanel

        AdvancedPreferences.registerDefaults(in: preferences)
        ForegroundSessionPreferences.registerDefaults(in: preferences)
        reportPreferenceWriteResult(AdvancedPreferences.writeScriptConfig(defaults: preferences))
        buildInterface()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Advanced")
        title.font = NSFont.boldSystemFont(ofSize: 24)
        let description = wrappedLabel("Configure Advanced preferences. Background-service, power-management, and an optional App Priority boost apply only when Performance Mode is explicitly turned ON. App Priority can temporarily set one selected app and verified helpers to nice -5, then restore recorded values on OFF or Emergency Restore. Memory / Storage and Thermal / Fan remain read-only and do not delete files, clear caches, tune memory, control fans, write SMC values, or change experimental system settings.")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(description)
        stack.addArrangedSubview(section("Background Services", controls: [
            advancedCheckbox("Pause Spotlight indexing while Performance Mode is ON", key: AdvancedPreferences.pauseSpotlightKey),
            advancedCheckbox("Pause Time Machine automatic backups while Performance Mode is ON", key: AdvancedPreferences.pauseTimeMachineKey),
            disabledCheckbox("Pause software update checks — Not implemented yet"),
            disabledCheckbox("Pause selected launch agents — Not implemented yet")
        ]))
        stack.addArrangedSubview(section("Power Behavior", controls: [
            advancedCheckbox("Prevent plugged-in system sleep while Performance Mode is ON", key: AdvancedPreferences.preventSystemSleepKey),
            advancedCheckbox("Prevent display sleep while Performance Mode is ON", key: AdvancedPreferences.preventDisplaySleepKey),
            disabledCheckbox("Prevent disk sleep — Not implemented yet"),
            disabledCheckbox("Disable Power Nap — Not implemented yet"),
            disabledCheckbox("Keep network awake — Not implemented yet")
        ]))
        if let foregroundView = foregroundPanelController?.makeSectionView() {
            stack.addArrangedSubview(foregroundView)
        }
        if let priorityView = appPriorityPanelController?.makeSectionView() {
            stack.addArrangedSubview(priorityView)
        }
        let memoryStorageButton = NSButton(title: "Run Memory / Storage Check", target: self, action: #selector(runMemoryStorageCheck))
        self.memoryStorageButton = memoryStorageButton
        stack.addArrangedSubview(section("Memory / Storage", controls: [
            wrappedLabel("Read-only warnings use conservative thresholds: swap above 1024 MB, disk free space below 10% or 10 GB, and macOS memory_pressure warn/critical output. These checks do not require sudo and do not modify the system."),
            advancedCheckbox("Show swap usage warning", key: AdvancedPreferences.showSwapUsageWarningKey),
            advancedCheckbox("Show low disk space warning", key: AdvancedPreferences.showLowDiskSpaceWarningKey),
            advancedCheckbox("Show memory pressure summary", key: AdvancedPreferences.showMemoryPressureSummaryKey),
            advancedCheckbox("Show top memory-heavy processes", key: AdvancedPreferences.showTopMemoryProcessesKey),
            memoryStorageButton,
            disabledCheckbox("Show top disk-heavy folders — Optional read-only scan not implemented yet"),
            disabledCheckbox("Cache cleanup tools — Not implemented yet — future manual-only feature"),
            disabledCheckbox("Browser cache cleanup — Not implemented yet — future manual-only feature"),
            disabledCheckbox("Automatic cleanup — Disabled and discouraged; not implemented")
        ]))
        let thermalFanButton = NSButton(title: "Run Thermal / Fan Check", target: self, action: #selector(runThermalFanCheck))
        self.thermalFanButton = thermalFanButton
        stack.addArrangedSubview(section("Thermal / Fan", controls: [
            wrappedLabel("Read-only monitoring only. The check reports thermal pressure/status when available, attempts to assess thermal constraints from safe built-in status output, and clearly warns when CPU temperature or fan RPM are unavailable without privileged or SMC access."),
            thermalFanButton,
            disabledCheckbox("Aggressive fan behavior — Not implemented yet"),
            disabledCheckbox("Max fans while Performance Mode is ON — Not implemented yet"),
            disabledCheckbox("Custom fan curve — Not implemented yet")
        ]))
        stack.addArrangedSubview(section("Experimental", controls: [
            disabledCheckbox("Turbo Boost detection — Not implemented yet"),
            disabledCheckbox("Turbo Boost control — Not implemented yet"),
            disabledCheckbox("MSR read access — Not implemented yet"),
            disabledCheckbox("Undervolting attempt — Not implemented yet"),
            disabledCheckbox("Legacy kext support — Not implemented yet")
        ]))
        stack.addArrangedSubview(section("Emergency / Restore", controls: [
            wrappedLabel("Emergency Restore remains available on the main screen and uses scripts/emergency_restore.sh. No additional restore behavior is controlled from this Advanced panel yet.")
        ]))

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedDocumentView(frame: .zero)
        documentView.translatesAutoresizingMaskIntoConstraints = true
        documentView.addSubview(stack)
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor)
        ])

        advancedScrollView = scrollView
        advancedDocumentView = documentView
        advancedStack = stack
        DispatchQueue.main.async { [weak self] in
            self?.updateAdvancedDocumentSize()
        }
    }

    private func updateAdvancedDocumentSize() {
        guard
            let scrollView = advancedScrollView,
            let documentView = advancedDocumentView,
            let stack = advancedStack
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
        foregroundPanelController?.updateApplicationListDocumentSize()
        documentView.layoutSubtreeIfNeeded()

        let requiredHeight = max(viewportSize.height, ceil(stack.fittingSize.height))
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: viewportSize.width,
            height: requiredHeight
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func windowDidResize(_ notification: Notification) {
        updateAdvancedDocumentSize()
    }

    private func section(_ title: String, controls: [NSView]) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = .labelColor

        let divider = NSBox()
        divider.boxType = .separator

        let header = NSStackView(views: [titleLabel, divider])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        let stack = NSStackView(views: [header] + controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 6
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .vertical)
        box.setContentCompressionResistancePriority(.required, for: .vertical)

        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let boxContentView = box.contentView else {
            return box
        }
        boxContentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: boxContentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: boxContentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: boxContentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: boxContentView.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28)
        ])

        return box
    }

    private func advancedCheckbox(_ title: String, key: String) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(savePreference(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier(rawValue: key)
        checkbox.state = preferences.bool(forKey: key) ? .on : .off
        return checkbox
    }

    private func disabledCheckbox(_ title: String) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        checkbox.isEnabled = false
        checkbox.state = .off
        checkbox.toolTip = "Placeholder only; this control is intentionally disabled and does not change the system."
        checkbox.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.disabledControlTextColor
            ]
        )
        return checkbox
    }

    func setScriptActionsEnabled(_ enabled: Bool, performanceModeIsOn: Bool) {
        memoryStorageButton?.isEnabled = enabled
        appPriorityPanelController?.setInteractionState(actionsEnabled: enabled, performanceModeIsOn: performanceModeIsOn)
        thermalFanButton?.isEnabled = enabled
        foregroundPanelController?.setActionsEnabled(enabled)
    }

    func updateForegroundSummary(from output: String) {
        foregroundPanelController?.updateSummary(from: output)
    }

    private func wrappedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func runMemoryStorageCheck() {
        reportPreferenceWriteResult(AdvancedPreferences.writeScriptConfig(defaults: preferences))
        onRunMemoryStorageCheck?()
    }

    @objc private func runThermalFanCheck() {
        onRunThermalFanCheck?()
    }

    @objc private func savePreference(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        preferences.set(sender.state == .on, forKey: key)
        reportPreferenceWriteResult(AdvancedPreferences.writeScriptConfig(defaults: preferences))
    }

    private func reportPreferenceWriteResult(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            let message = "Unable to write Advanced preferences to \(AdvancedPreferences.configFileURL.path): \(error.localizedDescription)"
            onPreferenceWriteFailure?(message)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AdvancedPreferences.registerDefaults()
        ForegroundSessionPreferences.registerDefaults()
        AppPriorityPreferences.registerDefaults()
        let controller = MainWindowController()
        do {
            try ForegroundSessionPreferences.load().write(to: ForegroundSessionPanelController.preferencesFileURL)
        } catch {
            controller.showPreferenceWriteFailure("Unable to write Foreground Session preferences to \(ForegroundSessionPanelController.preferencesFileURL.path): \(error.localizedDescription)")
        }
        do {
            try AppPriorityPreferences.load().writeAtomically(to: AppPriorityPanelController.preferencesFileURL)
        } catch {
            controller.showPreferenceWriteFailure("Unable to write App Priority preferences to \(AppPriorityPanelController.preferencesFileURL.path): \(error.localizedDescription)")
        }
        if case .failure(let error) = AdvancedPreferences.writeScriptConfig() {
            controller.showPreferenceWriteFailure("Unable to write Advanced preferences to \(AdvancedPreferences.configFileURL.path): \(error.localizedDescription)")
        }
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
