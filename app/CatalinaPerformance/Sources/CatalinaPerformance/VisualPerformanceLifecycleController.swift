#if canImport(AppKit)
import Foundation
import CatalinaPerformanceVisualPerformanceCore

final class VisualPerformanceLifecycleController {
    typealias SnapshotHandler = (VisualPerformanceStatusSnapshot) -> Void

    private let coordinator: VisualPerformanceCoordinator
    private let legacyRecovery: LegacyUIResponsivenessRecovery

    var onSnapshot: SnapshotHandler?
    var onLegacyRecoveryResult: ((LegacyUIResponsivenessRecoveryResult) -> Void)?

    init(
        runner: ScriptRunner,
        configDirectoryURL: URL = AdvancedPreferences.configDirectoryURL,
        requestingUID: UInt32 = UInt32(getuid())
    ) {
        let visualDirectory = configDirectoryURL
            .appendingPathComponent("visual_performance", isDirectory: true)
        coordinator = VisualPerformanceCoordinator(
            preferenceOperator: VisualPerformanceDefaultsOperator(),
            stateStore: VisualPerformanceStateStore(directoryURL: visualDirectory),
            requestingUID: requestingUID,
            callbackQueue: .main
        )
        let legacyStateFile = configDirectoryURL
            .appendingPathComponent("foreground_session", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("ui_preferences.tsv")
        legacyRecovery = LegacyUIResponsivenessRecovery(
            stateFileURL: legacyStateFile
        ) { completion in
            runner.run(.uiResponsivenessRestore, completion: completion)
        }
        coordinator.onSnapshot = { [weak self] snapshot in
            self?.onSnapshot?(snapshot)
        }
    }

    func recoverAtLaunch(
        performanceModeIsOn: Bool,
        completion: @escaping SnapshotHandler
    ) {
        legacyRecovery.recoverIfNeeded { [weak self] legacyResult in
            guard let self = self else { return }
            self.onLegacyRecoveryResult?(legacyResult)
            self.coordinator.recoverStaleSession(
                performanceModeIsOn: performanceModeIsOn,
                completion: completion
            )
        }
    }

    func prepareForPerformanceOn(completion: @escaping SnapshotHandler) {
        coordinator.prepareForPerformanceOn(completion: completion)
    }

    func restore(
        reason: VisualPerformanceRestoreReason,
        completion: @escaping SnapshotHandler
    ) {
        coordinator.restore(reason: reason, completion: completion)
    }

    func inspectCurrentSettings(
        completion: @escaping ([VisualCurrentSetting]) -> Void
    ) {
        coordinator.inspectCurrentSettings(completion: completion)
    }
}
#endif
