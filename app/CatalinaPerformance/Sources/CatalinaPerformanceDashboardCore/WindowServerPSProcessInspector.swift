import Foundation

public struct WindowServerProcessSample: Equatable {
    public let processKey: WindowServerProcessKey
    public let cumulativeCPUTimeNanoseconds: UInt64

    public init(
        processKey: WindowServerProcessKey,
        cumulativeCPUTimeNanoseconds: UInt64
    ) {
        self.processKey = processKey
        self.cumulativeCPUTimeNanoseconds = cumulativeCPUTimeNanoseconds
    }
}

public protocol WindowServerProcessInspecting: AnyObject {
    func readWindowServer() throws -> WindowServerProcessSample
}

enum WindowServerProcessInspectorError: Error, CustomStringConvertible {
    case commandTimedOut(String)
    case commandFailed(String, Int32?)
    case ambiguousProcess
    case invalidProcessRecord
    case unsafeExecutablePath

    var description: String {
        switch self {
        case .commandTimedOut(let command):
            return "\(command) timed out."
        case .commandFailed(let command, let status):
            if let status = status {
                return "\(command) exited with status \(status)."
            }
            return "\(command) could not be started."
        case .ambiguousProcess:
            return "WindowServer could not be identified uniquely."
        case .invalidProcessRecord:
            return "WindowServer process telemetry was malformed."
        case .unsafeExecutablePath:
            return "WindowServer executable identity was not the protected SkyLight path."
        }
    }
}

struct WindowServerCommandResult: Equatable {
    let output: String
    let errorOutput: String
    let exitStatus: Int32?
    let timedOut: Bool
}

protocol WindowServerCommandRunning: AnyObject {
    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> WindowServerCommandResult
}

final class FoundationWindowServerCommandRunner: WindowServerCommandRunning {
    func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> WindowServerCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return WindowServerCommandResult(
                output: "",
                errorOutput: error.localizedDescription,
                exitStatus: nil,
                timedOut: false
            )
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            if process.isRunning { process.terminate() }
            _ = semaphore.wait(timeout: .now() + 0.5)
            return WindowServerCommandResult(
                output: "",
                errorOutput: "Command timed out after \(timeout) seconds.",
                exitStatus: nil,
                timedOut: true
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return WindowServerCommandResult(
            output: String(data: outputData, encoding: .utf8) ?? "",
            errorOutput: String(data: errorData, encoding: .utf8) ?? "",
            exitStatus: process.terminationStatus,
            timedOut: false
        )
    }
}

struct WindowServerPSRecord: Equatable {
    let pid: Int32
    let effectiveUID: UInt32
    let parentPID: Int32
    let startedAt: Date
    let cpuTimeNanoseconds: UInt64
    let executablePath: String
}

enum WindowServerPSParser {
    static func cpuTimeNanoseconds(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var dayCount: Double = 0
        var clockText = trimmed
        if let dashIndex = clockText.firstIndex(of: "-") {
            let dayText = String(clockText[..<dashIndex])
            guard let days = Double(dayText), days >= 0 else { return nil }
            dayCount = days
            clockText = String(clockText[clockText.index(after: dashIndex)...])
        }

        let parts = clockText
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let secondsText = parts.last,
              let seconds = Double(secondsText),
              seconds >= 0,
              seconds < 60 else {
            return nil
        }
        guard let minutes = Double(parts[parts.count - 2]),
              minutes >= 0,
              minutes < 60 else {
            return nil
        }

        var hours: Double = 0
        if parts.count == 3 {
            guard let parsedHours = Double(parts[0]), parsedHours >= 0 else {
                return nil
            }
            if dayCount > 0 && parsedHours >= 24 { return nil }
            hours = parsedHours
        } else if dayCount > 0 {
            return nil
        }

        let totalSeconds = dayCount * 86_400.0 + hours * 3_600.0 + minutes * 60.0 + seconds
        guard totalSeconds.isFinite, totalSeconds >= 0 else { return nil }
        let nanoseconds = totalSeconds * 1_000_000_000.0
        guard nanoseconds.isFinite, nanoseconds <= Double(UInt64.max) else { return nil }
        return UInt64(nanoseconds.rounded())
    }

    static func parseRecord(
        _ output: String,
        timeZone: TimeZone = TimeZone.current
    ) -> WindowServerPSRecord? {
        let lines = output
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 1 else { return nil }

        let fields = lines[0].split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count >= 10,
              let pidValue = Int32(fields[0]),
              pidValue > 0,
              let uidValue = UInt32(fields[1]),
              let parentPIDValue = Int32(fields[2]),
              let cpuNanoseconds = cpuTimeNanoseconds(fields[8]) else {
            return nil
        }

        let dateText = fields[3...7].joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let startedAt = formatter.date(from: dateText) else { return nil }

        let executablePath = fields[9]
        guard executablePath.hasPrefix("/") else { return nil }

        return WindowServerPSRecord(
            pid: pidValue,
            effectiveUID: uidValue,
            parentPID: parentPIDValue,
            startedAt: startedAt,
            cpuTimeNanoseconds: cpuNanoseconds,
            executablePath: executablePath
        )
    }
}

public final class DarwinWindowServerProcessInspector: WindowServerProcessInspecting {
    private static let pgrepPath = "/usr/bin/pgrep"
    private static let psPath = "/bin/ps"
    private static let commandTimeout: TimeInterval = 1.0

    private let commandRunner: WindowServerCommandRunning
    private let timeZone: TimeZone

    init(
        commandRunner: WindowServerCommandRunning = FoundationWindowServerCommandRunner(),
        timeZone: TimeZone = TimeZone.current
    ) {
        self.commandRunner = commandRunner
        self.timeZone = timeZone
    }

    public func readWindowServer() throws -> WindowServerProcessSample {
        let pgrep = commandRunner.run(
            executablePath: Self.pgrepPath,
            arguments: ["-x", "WindowServer"],
            timeout: Self.commandTimeout
        )
        if pgrep.timedOut {
            throw WindowServerProcessInspectorError.commandTimedOut("pgrep")
        }
        guard pgrep.exitStatus == 0 else {
            throw WindowServerProcessInspectorError.commandFailed("pgrep", pgrep.exitStatus)
        }

        let pidValues = pgrep.output
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int32(String($0)) }
            .filter { $0 > 0 }
        guard pidValues.count == 1, let pid = pidValues.first else {
            throw WindowServerProcessInspectorError.ambiguousProcess
        }

        let ps = commandRunner.run(
            executablePath: Self.psPath,
            arguments: [
                "-ww",
                "-p", String(pid),
                "-o", "pid=",
                "-o", "uid=",
                "-o", "ppid=",
                "-o", "lstart=",
                "-o", "time=",
                "-o", "command="
            ],
            timeout: Self.commandTimeout
        )
        if ps.timedOut {
            throw WindowServerProcessInspectorError.commandTimedOut("ps")
        }
        guard ps.exitStatus == 0 else {
            throw WindowServerProcessInspectorError.commandFailed("ps", ps.exitStatus)
        }
        guard let record = WindowServerPSParser.parseRecord(ps.output, timeZone: timeZone),
              record.pid == pid,
              record.parentPID == 1 else {
            throw WindowServerProcessInspectorError.invalidProcessRecord
        }
        guard isProtectedWindowServerPath(record.executablePath) else {
            throw WindowServerProcessInspectorError.unsafeExecutablePath
        }

        let startSeconds = Int64(record.startedAt.timeIntervalSince1970.rounded(.towardZero))
        let key = WindowServerProcessKey(
            pid: record.pid,
            effectiveUID: record.effectiveUID,
            executablePath: record.executablePath,
            startSeconds: startSeconds,
            startMicroseconds: 0
        )
        return WindowServerProcessSample(
            processKey: key,
            cumulativeCPUTimeNanoseconds: record.cpuTimeNanoseconds
        )
    }

    private func isProtectedWindowServerPath(_ path: String) -> Bool {
        let prefix = "/System/Library/PrivateFrameworks/SkyLight.framework/"
        return path.hasPrefix(prefix) && path.hasSuffix("/Resources/WindowServer")
    }
}
