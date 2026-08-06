import Foundation
import CatalinaPerformanceVisualPerformanceCore

struct VisualDefaultsCommandResult: Equatable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

protocol VisualDefaultsCommandRunning: AnyObject {
    func run(arguments: [String]) throws -> VisualDefaultsCommandResult
}

enum VisualPerformanceDefaultsOperatorError: Error, LocalizedError {
    case unapprovedCatalogEntry
    case commandFailed(String)
    case commandTimedOut
    case unsupportedType(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .unapprovedCatalogEntry:
            return "The requested visual setting is not in the static Catalina allowlist."
        case .commandFailed(let message):
            return message
        case .commandTimedOut:
            return "The defaults command timed out."
        case .unsupportedType(let typeName):
            return "Unsupported defaults value type: \(typeName)"
        case .invalidValue(let value):
            return "Unable to parse the defaults value safely: \(value)"
        }
    }
}

final class VisualDefaultsCommandRunner: VisualDefaultsCommandRunning {
    private let executableURL: URL
    private let timeout: TimeInterval

    init(executablePath: String = "/usr/bin/defaults", timeout: TimeInterval = 3.0) {
        self.executableURL = URL(fileURLWithPath: executablePath)
        self.timeout = timeout
    }

    func run(arguments: [String]) throws -> VisualDefaultsCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()

        let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
        if timedOut && process.isRunning {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1.0)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        let status: Int32 = process.isRunning ? -1 : process.terminationStatus
        return VisualDefaultsCommandResult(
            exitStatus: status,
            standardOutput: output,
            standardError: error,
            timedOut: timedOut
        )
    }
}

final class VisualPerformanceDefaultsOperator: VisualPreferenceOperating {
    private let runner: VisualDefaultsCommandRunning
    private let catalog: CatalinaVisualPerformanceCatalog

    init(
        runner: VisualDefaultsCommandRunning = VisualDefaultsCommandRunner(),
        catalog: CatalinaVisualPerformanceCatalog = .current
    ) {
        self.runner = runner
        self.catalog = catalog
    }

    func read(_ entry: VisualSettingCatalogEntry) throws -> VisualPreferenceObservation {
        try validate(entry)
        let typeResult = try runner.run(arguments: ["read-type", entry.domain, entry.key])
        if typeResult.timedOut {
            throw VisualPerformanceDefaultsOperatorError.commandTimedOut
        }

        let valueResult = try runner.run(arguments: ["read", entry.domain, entry.key])
        if valueResult.timedOut {
            throw VisualPerformanceDefaultsOperatorError.commandTimedOut
        }
        if typeResult.exitStatus != 0 && valueResult.exitStatus != 0 {
            return .absent
        }
        guard valueResult.exitStatus == 0 else {
            throw VisualPerformanceDefaultsOperatorError.commandFailed(
                nonempty(valueResult.standardError, fallback: "defaults read failed.")
            )
        }
        guard typeResult.exitStatus == 0 else {
            return .unsupportedType(nonempty(typeResult.standardError, fallback: "unknown"))
        }

        guard let scalarType = scalarType(from: typeResult.standardOutput) else {
            return .unsupportedType(
                typeResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard let value = VisualScalarNormalizer.value(
            from: valueResult.standardOutput,
            expectedType: scalarType
        ) else {
            throw VisualPerformanceDefaultsOperatorError.invalidValue(valueResult.standardOutput)
        }
        return .present(value)
    }

    func writeAppliedValue(_ entry: VisualSettingCatalogEntry) throws {
        try validate(entry)
        try write(entry.appliedValue, for: entry)
    }

    func write(_ value: VisualScalarValue, for entry: VisualSettingCatalogEntry) throws {
        try validate(entry)
        let arguments = ["write", entry.domain, entry.key] + writeArguments(for: value)
        let result = try runner.run(arguments: arguments)
        try requireSuccess(result, operation: "defaults write")
    }

    func delete(_ entry: VisualSettingCatalogEntry) throws {
        try validate(entry)
        let result = try runner.run(arguments: ["delete", entry.domain, entry.key])
        try requireSuccess(result, operation: "defaults delete")
    }

    func isDockAutoHideEnabled() throws -> Bool {
        let result = try runner.run(arguments: ["read", "com.apple.dock", "autohide"])
        if result.timedOut {
            throw VisualPerformanceDefaultsOperatorError.commandTimedOut
        }
        if result.exitStatus != 0 {
            return false
        }
        guard let value = VisualScalarNormalizer.boolean(from: result.standardOutput) else {
            throw VisualPerformanceDefaultsOperatorError.invalidValue(result.standardOutput)
        }
        return value
    }

    private func validate(_ entry: VisualSettingCatalogEntry) throws {
        guard catalog[entry.id] == entry else {
            throw VisualPerformanceDefaultsOperatorError.unapprovedCatalogEntry
        }
    }

    private func scalarType(from output: String) -> VisualScalarType? {
        let normalized = output.lowercased()
        if normalized.contains("boolean") { return .boolean }
        if normalized.contains("integer") { return .integer }
        if normalized.contains("float") || normalized.contains("double") || normalized.contains("real") {
            return .floatingPoint
        }
        if normalized.contains("string") { return .string }
        return nil
    }

    private func writeArguments(for value: VisualScalarValue) -> [String] {
        switch value {
        case .boolean(let bool):
            return ["-bool", bool ? "true" : "false"]
        case .integer(let integer):
            return ["-int", String(integer)]
        case .floatingPoint(let floatingPoint):
            return ["-float", String(floatingPoint)]
        case .string(let string):
            return ["-string", string]
        }
    }

    private func requireSuccess(_ result: VisualDefaultsCommandResult, operation: String) throws {
        if result.timedOut {
            throw VisualPerformanceDefaultsOperatorError.commandTimedOut
        }
        guard result.exitStatus == 0 else {
            throw VisualPerformanceDefaultsOperatorError.commandFailed(
                nonempty(result.standardError, fallback: operation + " failed.")
            )
        }
    }

    private func nonempty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
