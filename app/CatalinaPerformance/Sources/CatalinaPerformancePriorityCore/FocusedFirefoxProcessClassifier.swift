import Foundation

public enum FocusedFirefoxProcessRole: String, Codable, Equatable {
    case parentUI
    case gpuHelper
    case contentStyle
}

public struct FocusedFirefoxClassifiedProcesses: Equatable {
    public let tracked: [AppPriorityProcessIdentity]
    public let parent: AppPriorityProcessIdentity?
    public let gpu: AppPriorityProcessIdentity?
    public let contentStyle: [AppPriorityProcessIdentity]
    public let skippedCount: Int
    public let warnings: [String]

    public init(
        tracked: [AppPriorityProcessIdentity],
        parent: AppPriorityProcessIdentity?,
        gpu: AppPriorityProcessIdentity?,
        contentStyle: [AppPriorityProcessIdentity],
        skippedCount: Int,
        warnings: [String]
    ) {
        self.tracked = tracked
        self.parent = parent
        self.gpu = gpu
        self.contentStyle = contentStyle
        self.skippedCount = skippedCount
        self.warnings = warnings
    }

    public var trackedProcessCount: Int {
        return tracked.count
    }
}

public enum FocusedFirefoxProcessClassifier {
    public static func classify(
        application: AppPriorityApplication,
        requestingUID: UInt32,
        processes: [AppPriorityProcessIdentity],
        argumentsByPID: [Int32: [String]]
    ) -> FocusedFirefoxClassifiedProcesses {
        let family = AppPriorityProcessFamilyResolver.resolve(
            application: application,
            requestingUID: requestingUID,
            processes: processes,
            policyKind: .focusedFirefox
        )
        let tracked = family.eligible.sorted { $0.pid < $1.pid }
        let bundleURL = URL(fileURLWithPath: application.bundlePath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalParent = URL(fileURLWithPath: application.executablePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let pluginContainer = bundleURL.appendingPathComponent(
            "Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container",
            isDirectory: false
        ).standardizedFileURL.path
        let gpuHelper = bundleURL.appendingPathComponent(
            "Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper",
            isDirectory: false
        ).standardizedFileURL.path

        var warnings: [String] = []
        let parentCandidates = tracked.filter {
            $0.effectiveUID == requestingUID && $0.executablePath == canonicalParent
        }
        let parent: AppPriorityProcessIdentity?
        if parentCandidates.count == 1 {
            parent = parentCandidates[0]
        } else {
            parent = nil
            if parentCandidates.count > 1 {
                warnings.append("Multiple Firefox parent processes matched canonical identity.")
            } else if family.mainProcessFound {
                warnings.append("Firefox parent process could not be classified unambiguously.")
            }
        }

        guard let verifiedParent = parent else {
            return FocusedFirefoxClassifiedProcesses(
                tracked: tracked,
                parent: nil,
                gpu: nil,
                contentStyle: [],
                skippedCount: family.skipped.count,
                warnings: warnings
            )
        }

        let directChildren = tracked.filter { $0.parentPID == verifiedParent.pid }
        let gpuCandidates = directChildren.filter { process in
            guard process.executablePath == gpuHelper,
                  let arguments = argumentsByPID[process.pid],
                  arguments.last == "gpu" else {
                return false
            }
            return true
        }
        let gpu: AppPriorityProcessIdentity?
        if gpuCandidates.count == 1 {
            gpu = gpuCandidates[0]
        } else {
            gpu = nil
            if gpuCandidates.count > 1 {
                warnings.append("Multiple Firefox GPU helpers matched the focused role.")
            }
        }

        let content = directChildren.filter { process in
            guard process.executablePath == pluginContainer,
                  let arguments = argumentsByPID[process.pid],
                  arguments.contains("-isForBrowser"),
                  arguments.last == "tab" else {
                return false
            }
            return true
        }.sorted { $0.pid < $1.pid }

        return FocusedFirefoxClassifiedProcesses(
            tracked: tracked,
            parent: verifiedParent,
            gpu: gpu,
            contentStyle: content,
            skippedCount: family.skipped.count,
            warnings: warnings
        )
    }
}
