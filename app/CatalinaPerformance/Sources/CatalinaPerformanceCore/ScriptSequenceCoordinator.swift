import Foundation

public enum SequenceScript: String, Hashable {
    case performanceOn
    case performanceOff
    case foregroundApply
    case foregroundApplyDryRun
    case foregroundRestore
    case foregroundRestoreDryRun
    case foregroundState
    case uiApply
    case uiApplyDryRun
    case uiRestore
    case uiRestoreDryRun
}

public struct SequenceCommandResult: Equatable {
    public let script: SequenceScript
    public let command: String
    public let output: String
    public let succeeded: Bool

    public init(script: SequenceScript, command: String, output: String, succeeded: Bool) {
        self.script = script
        self.command = command
        self.output = output
        self.succeeded = succeeded
    }
}

public protocol SequenceScriptExecuting: AnyObject {
    func execute(_ script: SequenceScript, completion: @escaping (SequenceCommandResult) -> Void)
}

public struct ScriptSequenceStep: Equatable {
    public let script: SequenceScript
    public let continueAfterFailure: Bool
    public let rollbackOnFailure: [SequenceScript]

    public init(script: SequenceScript, continueAfterFailure: Bool = false, rollbackOnFailure: [SequenceScript] = []) {
        self.script = script
        self.continueAfterFailure = continueAfterFailure
        self.rollbackOnFailure = rollbackOnFailure
    }
}

public struct ScriptSequenceResult: Equatable {
    public let commandResults: [SequenceCommandResult]
    public let hadPrimaryFailure: Bool

    public var succeeded: Bool {
        return !hadPrimaryFailure && commandResults.allSatisfy { $0.succeeded }
    }

    public var executedScripts: [SequenceScript] {
        return commandResults.map { $0.script }
    }
}

public final class ScriptSequenceCoordinator {
    private let executor: SequenceScriptExecuting

    public init(executor: SequenceScriptExecuting) {
        self.executor = executor
    }

    public func run(steps: [ScriptSequenceStep], completion: @escaping (ScriptSequenceResult) -> Void) {
        var results: [SequenceCommandResult] = []
        var hadPrimaryFailure = false
        var didComplete = false

        func finish() {
            guard !didComplete else { return }
            didComplete = true
            completion(ScriptSequenceResult(commandResults: results, hadPrimaryFailure: hadPrimaryFailure))
        }

        func runScripts(_ scripts: [SequenceScript], index: Int, then next: @escaping () -> Void) {
            guard index < scripts.count else {
                next()
                return
            }
            executor.execute(scripts[index]) { result in
                results.append(result)
                runScripts(scripts, index: index + 1, then: next)
            }
        }

        func runStep(_ index: Int) {
            guard index < steps.count else {
                finish()
                return
            }
            let step = steps[index]
            executor.execute(step.script) { result in
                results.append(result)
                if result.succeeded {
                    runStep(index + 1)
                    return
                }

                hadPrimaryFailure = true
                runScripts(step.rollbackOnFailure, index: 0) {
                    if step.continueAfterFailure {
                        runStep(index + 1)
                    } else {
                        finish()
                    }
                }
            }
        }

        runStep(0)
    }
}

public enum PerformanceSequenceFactory {
    public static func performanceOn(featureEnabled: Bool) -> [ScriptSequenceStep] {
        guard featureEnabled else { return [ScriptSequenceStep(script: .performanceOn)] }
        return [
            ScriptSequenceStep(script: .foregroundApply),
            ScriptSequenceStep(script: .uiApply, rollbackOnFailure: [.foregroundRestore]),
            ScriptSequenceStep(script: .performanceOn, rollbackOnFailure: [.uiRestore, .foregroundRestore])
        ]
    }

    public static func performanceOff(featureEnabled: Bool) -> [ScriptSequenceStep] {
        guard featureEnabled else { return [ScriptSequenceStep(script: .performanceOff)] }
        return [
            ScriptSequenceStep(script: .performanceOff, continueAfterFailure: true),
            ScriptSequenceStep(script: .uiRestore, continueAfterFailure: true),
            ScriptSequenceStep(script: .foregroundRestore, continueAfterFailure: true)
        ]
    }

    public static func manualDryRun() -> [ScriptSequenceStep] {
        return [
            ScriptSequenceStep(script: .foregroundApplyDryRun),
            ScriptSequenceStep(script: .uiApplyDryRun)
        ]
    }

    public static func manualApply() -> [ScriptSequenceStep] {
        return [
            ScriptSequenceStep(script: .foregroundApply),
            ScriptSequenceStep(script: .uiApply, rollbackOnFailure: [.foregroundRestore])
        ]
    }

    public static func manualRestore() -> [ScriptSequenceStep] {
        return [
            ScriptSequenceStep(script: .uiRestore, continueAfterFailure: true),
            ScriptSequenceStep(script: .foregroundRestore, continueAfterFailure: true)
        ]
    }
}
