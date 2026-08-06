#if canImport(AppKit)
import Foundation

struct LegacyUIResponsivenessRecoveryResult: Equatable {
    let state: String
    let pendingCount: Int
    let output: String

    var hasUnresolvedWork: Bool {
        return state == "pending" || state == "failed" || pendingCount > 0
    }
}

final class LegacyUIResponsivenessRecovery {
    typealias RestoreRunner = (@escaping (ScriptResult) -> Void) -> Void

    private let fileManager: FileManager
    private let stateFileURL: URL
    private let workQueue: DispatchQueue
    private let restoreRunner: RestoreRunner

    init(
        stateFileURL: URL,
        fileManager: FileManager = .default,
        workQueue: DispatchQueue = DispatchQueue(
            label: "CatalinaPerformance.LegacyUIRecovery",
            qos: .utility
        ),
        restoreRunner: @escaping RestoreRunner
    ) {
        self.stateFileURL = stateFileURL
        self.fileManager = fileManager
        self.workQueue = workQueue
        self.restoreRunner = restoreRunner
    }

    func recoverIfNeeded(
        completion: @escaping (LegacyUIResponsivenessRecoveryResult) -> Void
    ) {
        workQueue.async {
            let pending = self.pendingCount()
            guard pending > 0 else {
                DispatchQueue.main.async {
                    completion(
                        LegacyUIResponsivenessRecoveryResult(
                            state: "none",
                            pendingCount: 0,
                            output: "No unresolved legacy UI responsiveness state exists."
                        )
                    )
                }
                return
            }

            DispatchQueue.main.async {
                self.restoreRunner { result in
                    completion(self.parse(result: result, fallbackPending: pending))
                }
            }
        }
    }

    private func pendingCount() -> Int {
        guard fileManager.isReadableFile(atPath: stateFileURL.path),
              let contents = try? String(contentsOf: stateFileURL, encoding: .utf8) else {
            return 0
        }
        return contents
            .split(whereSeparator: { $0.isNewline })
            .dropFirst()
            .reduce(0) { count, line in
                let columns = line.split(
                    separator: "\t",
                    omittingEmptySubsequences: false
                )
                guard columns.count >= 8 else { return count + 1 }
                return columns[7] == "restored" ? count : count + 1
            }
    }

    private func parse(
        result: ScriptResult,
        fallbackPending: Int
    ) -> LegacyUIResponsivenessRecoveryResult {
        var state = result.succeeded ? "restored" : "failed"
        var pending = result.succeeded ? 0 : fallbackPending
        result.output.split(whereSeparator: { $0.isNewline }).forEach { line in
            let parts = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2 else { return }
            if parts[0] == "legacy_ui_state" {
                state = String(parts[1])
            } else if parts[0] == "legacy_ui_pending_count",
                      let value = Int(parts[1]) {
                pending = value
            }
        }
        return LegacyUIResponsivenessRecoveryResult(
            state: state,
            pendingCount: pending,
            output: result.output
        )
    }
}
#endif
