import Foundation

public struct ThermalLimitSnapshot: Codable, Equatable {
    public let capturedAt: Date
    public let schedulerLimitPercent: MetricReading<Double>
    public let speedLimitPercent: MetricReading<Double>

    public init(capturedAt: Date, schedulerLimitPercent: MetricReading<Double>, speedLimitPercent: MetricReading<Double>) {
        self.capturedAt = capturedAt
        self.schedulerLimitPercent = schedulerLimitPercent
        self.speedLimitPercent = speedLimitPercent
    }
}

public enum ThermalLimitParser {
    public static func parse(_ output: String, capturedAt: Date) -> ThermalLimitSnapshot {
        var scheduler: Double?
        var speed: Double?
        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueText = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(valueText), value >= 0, value <= 100 else { continue }
            if key == "CPU_Scheduler_Limit" { scheduler = value }
            if key == "CPU_Speed_Limit" { speed = value }
        }
        let unavailable = "No percentage thermal limit was reported by pmset."
        return ThermalLimitSnapshot(
            capturedAt: capturedAt,
            schedulerLimitPercent: scheduler.map { .available($0, at: capturedAt) } ?? .unavailable(at: capturedAt, note: unavailable),
            speedLimitPercent: speed.map { .available($0, at: capturedAt) } ?? .unavailable(at: capturedAt, note: unavailable)
        )
    }
}

public protocol ThermalLimitProviding {
    func readLimits(capturedAt: Date) -> ThermalLimitSnapshot
}

public struct ThermalCommandResult: Equatable {
    public let output: String
    public let errorOutput: String
    public let exitStatus: Int32?
    public let timedOut: Bool

    public init(output: String, errorOutput: String, exitStatus: Int32?, timedOut: Bool) {
        self.output = output
        self.errorOutput = errorOutput
        self.exitStatus = exitStatus
        self.timedOut = timedOut
    }
}

public protocol ThermalCommandRunning: AnyObject {
    func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> ThermalCommandResult
}

public final class FoundationThermalCommandRunner: ThermalCommandRunning {
    public init() {}

    public func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> ThermalCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            return ThermalCommandResult(output: "", errorOutput: error.localizedDescription, exitStatus: nil, timedOut: false)
        }
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            if process.isRunning { process.terminate() }
            _ = semaphore.wait(timeout: .now() + 1.0)
            return ThermalCommandResult(output: "", errorOutput: "pmset timed out after \(timeout) seconds.", exitStatus: nil, timedOut: true)
        }
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ThermalCommandResult(output: output, errorOutput: error, exitStatus: process.terminationStatus, timedOut: false)
    }
}

public final class PMSetThermalLimitProvider: ThermalLimitProviding {
    private let executablePath: String
    private let timeout: TimeInterval
    private let commandRunner: ThermalCommandRunning

    public init(
        executablePath: String = "/usr/bin/pmset",
        timeout: TimeInterval = 2.0,
        commandRunner: ThermalCommandRunning = FoundationThermalCommandRunner()
    ) {
        self.executablePath = executablePath
        self.timeout = timeout
        self.commandRunner = commandRunner
    }

    public func readLimits(capturedAt: Date) -> ThermalLimitSnapshot {
        let result = commandRunner.run(executablePath: executablePath, arguments: ["-g", "therm"], timeout: timeout)
        guard !result.timedOut else {
            return unavailable(at: capturedAt, note: result.errorOutput)
        }
        guard result.exitStatus == 0 else {
            let note = result.errorOutput.isEmpty ? "pmset exited without usable thermal data." : result.errorOutput
            return unavailable(at: capturedAt, note: note)
        }
        return ThermalLimitParser.parse(result.output, capturedAt: capturedAt)
    }

    private func unavailable(at date: Date, note: String) -> ThermalLimitSnapshot {
        ThermalLimitSnapshot(
            capturedAt: date,
            schedulerLimitPercent: .unavailable(at: date, note: note),
            speedLimitPercent: .unavailable(at: date, note: note)
        )
    }
}
