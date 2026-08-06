import Foundation

public struct AppPriorityProcessFamilyResult: Equatable {
    public let eligible: [AppPriorityProcessIdentity]
    public let skipped: [AppPriorityProcessIdentity]
    public let mainProcessFound: Bool

    public init(eligible: [AppPriorityProcessIdentity], skipped: [AppPriorityProcessIdentity], mainProcessFound: Bool) {
        self.eligible = eligible
        self.skipped = skipped
        self.mainProcessFound = mainProcessFound
    }
}

public enum AppPriorityProcessFamilyResolver {
    private static let excludedNames: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow", "systemuiserver",
        "dock", "finder", "catalinaperformance", "catalinaperformancepriorityagent"
    ]

    public static func resolve(
        application: AppPriorityApplication,
        requestingUID: UInt32,
        processes: [AppPriorityProcessIdentity],
        policyKind: AppPriorityPolicyKind = .verifiedProcessFamily
    ) -> AppPriorityProcessFamilyResult {
        let bundleURL = URL(fileURLWithPath: application.bundlePath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let executablePath = URL(fileURLWithPath: application.executablePath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let helperRoots = ["MacOS", "Frameworks", "Helpers", "XPCServices", "PlugIns"].map {
            bundleURL.appendingPathComponent("Contents/\($0)", isDirectory: true).path
        }

        let mainPIDs = Set(processes.filter {
            $0.effectiveUID == requestingUID && $0.executablePath == executablePath
        }.map { $0.pid })
        var associatedPIDs = mainPIDs
        if policyKind != .mainProcessOnly {
            var changed = true
            var depth = 0
            while changed && depth < 64 {
                changed = false
                depth += 1
                for process in processes where process.effectiveUID == requestingUID {
                    if associatedPIDs.contains(process.parentPID) && !associatedPIDs.contains(process.pid) {
                        associatedPIDs.insert(process.pid)
                        changed = true
                    }
                }
            }
        }

        var eligible: [AppPriorityProcessIdentity] = []
        var skipped: [AppPriorityProcessIdentity] = []
        for process in processes {
            let insideHelperLocation = policyKind != .mainProcessOnly && helperRoots.contains { root in
                process.executablePath == root || process.executablePath.hasPrefix(root + "/")
            }
            let associated = associatedPIDs.contains(process.pid) || insideHelperLocation
            guard associated else { continue }
            if isSafe(process, requestingUID: requestingUID) {
                eligible.append(process)
            } else {
                skipped.append(process)
            }
        }

        eligible.sort { $0.pid < $1.pid }
        skipped.sort { $0.pid < $1.pid }
        return AppPriorityProcessFamilyResult(eligible: eligible, skipped: skipped, mainProcessFound: !mainPIDs.isEmpty)
    }

    private static func isSafe(_ process: AppPriorityProcessIdentity, requestingUID: UInt32) -> Bool {
        if process.pid == 0 || process.pid == 1 { return false }
        if process.effectiveUID == 0 || process.effectiveUID != requestingUID { return false }
        let normalizedName = process.processName.lowercased()
        if excludedNames.contains(normalizedName) { return false }
        let basename = URL(fileURLWithPath: process.executablePath).lastPathComponent.lowercased()
        if excludedNames.contains(basename) { return false }
        return !process.executablePath.isEmpty
    }
}
