import Foundation
import CatalinaPerformancePriorityCore

public struct MemoryProcessObservation: Equatable {
    public let identity: AppPriorityProcessIdentity
    public let residentBytes: UInt64

    public init(identity: AppPriorityProcessIdentity, residentBytes: UInt64) {
        self.identity = identity
        self.residentBytes = residentBytes
    }
}

public struct MemoryProcessFamilyCandidate: Equatable {
    public let identifier: String
    public let displayName: String
    public let bundlePath: String
    public let processes: [MemoryProcessObservation]
    public let residentBytes: UInt64
    public let residentGrowthBytes: UInt64
    public let backgroundSampleCount: Int

    public init(
        identifier: String,
        displayName: String,
        bundlePath: String,
        processes: [MemoryProcessObservation],
        residentBytes: UInt64,
        residentGrowthBytes: UInt64,
        backgroundSampleCount: Int
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.bundlePath = bundlePath
        self.processes = processes
        self.residentBytes = residentBytes
        self.residentGrowthBytes = residentGrowthBytes
        self.backgroundSampleCount = backgroundSampleCount
    }
}

public struct MemoryProcessFamilyAnalyzer {
    private struct FamilyHistory {
        var backgroundSampleCount: Int
        var lastResidentBytes: UInt64
    }

    private static let minimumFamilyBytes: UInt64 = 256 * 1_048_576
    private static let protectedProcessNames: Set<String> = [
        "launchd",
        "kernel_task",
        "windowserver",
        "loginwindow",
        "systemuiserver",
        "finder",
        "dock",
        "catalinaperformance",
        "catalinaperformancepriorityagent",
        "catalinaperformancememoryagent"
    ]

    private var historyByFamily: [String: FamilyHistory] = [:]

    public init() {}

    public mutating func rankEligibleFamilies(
        processes: [AppPriorityProcessIdentity],
        currentUID: UInt32,
        physicalBytes: UInt64,
        frontmostApplication: AppPriorityApplication?,
        appPriorityApplication: AppPriorityApplication?,
        resourceInspector: AppPriorityProcessResourceInspecting
    ) -> [MemoryProcessFamilyCandidate] {
        guard currentUID > 0,
              physicalBytes > 0,
              let frontmostApplication = frontmostApplication else {
            return []
        }

        let frontmostIdentifier = canonicalBundleIdentifier(frontmostApplication.bundlePath)
        let priorityIdentifier = appPriorityApplication.map { canonicalBundleIdentifier($0.bundlePath) }
        let groups = buildGroups(
            processes: processes,
            currentUID: currentUID,
            resourceInspector: resourceInspector
        )

        let fivePercent = physicalBytes / 20
        let significanceThreshold = max(Self.minimumFamilyBytes, fivePercent)
        var candidates: [MemoryProcessFamilyCandidate] = []
        var seenIdentifiers: Set<String> = []

        for group in groups {
            seenIdentifiers.insert(group.identifier)
            let previous = historyByFamily[group.identifier]
            let growth: UInt64
            if let previous = previous, group.residentBytes >= previous.lastResidentBytes {
                growth = group.residentBytes - previous.lastResidentBytes
            } else {
                growth = 0
            }

            let isForeground = group.identifier == frontmostIdentifier
            let isPriorityTarget = priorityIdentifier != nil && group.identifier == priorityIdentifier
            let backgroundCount: Int
            if isForeground || isPriorityTarget {
                backgroundCount = 0
            } else {
                backgroundCount = min((previous?.backgroundSampleCount ?? 0) + 1, Int.max - 1)
            }

            historyByFamily[group.identifier] = FamilyHistory(
                backgroundSampleCount: backgroundCount,
                lastResidentBytes: group.residentBytes
            )

            guard !isForeground,
                  !isPriorityTarget,
                  backgroundCount >= 3,
                  group.residentBytes >= significanceThreshold else {
                continue
            }

            candidates.append(MemoryProcessFamilyCandidate(
                identifier: group.identifier,
                displayName: group.displayName,
                bundlePath: group.bundlePath,
                processes: group.processes,
                residentBytes: group.residentBytes,
                residentGrowthBytes: growth,
                backgroundSampleCount: backgroundCount
            ))
        }

        historyByFamily = historyByFamily.filter { seenIdentifiers.contains($0.key) }

        candidates.sort { lhs, rhs in
            if lhs.residentBytes != rhs.residentBytes {
                return lhs.residentBytes > rhs.residentBytes
            }
            if lhs.residentGrowthBytes != rhs.residentGrowthBytes {
                return lhs.residentGrowthBytes > rhs.residentGrowthBytes
            }
            if lhs.backgroundSampleCount != rhs.backgroundSampleCount {
                return lhs.backgroundSampleCount > rhs.backgroundSampleCount
            }
            return lhs.identifier < rhs.identifier
        }

        if candidates.count > 3 {
            return Array(candidates.prefix(3))
        }
        return candidates
    }

    private struct FamilyGroup {
        let identifier: String
        let displayName: String
        let bundlePath: String
        let processes: [MemoryProcessObservation]
        let residentBytes: UInt64
    }

    private func buildGroups(
        processes: [AppPriorityProcessIdentity],
        currentUID: UInt32,
        resourceInspector: AppPriorityProcessResourceInspecting
    ) -> [FamilyGroup] {
        var grouped: [String: (bundlePath: String, processes: [MemoryProcessObservation], residentBytes: UInt64)] = [:]
        var seenPIDs: Set<Int32> = []

        for process in processes {
            guard process.pid > 0,
                  process.effectiveUID == currentUID,
                  process.effectiveUID != 0,
                  !seenPIDs.contains(process.pid),
                  !Self.protectedProcessNames.contains(process.processName.lowercased()),
                  let bundlePath = applicationBundlePath(forExecutablePath: process.executablePath),
                  isAllowedApplicationBundlePath(bundlePath) else {
                continue
            }

            let identifier = canonicalBundleIdentifier(bundlePath)
            guard !identifier.isEmpty else { continue }

            let residentBytes: UInt64
            do {
                residentBytes = try resourceInspector.residentBytes(pid: process.pid)
            } catch {
                continue
            }

            seenPIDs.insert(process.pid)
            let observation = MemoryProcessObservation(identity: process, residentBytes: residentBytes)
            var value = grouped[identifier] ?? (bundlePath: bundlePath, processes: [], residentBytes: 0)
            value.processes.append(observation)
            let sum = value.residentBytes.addingReportingOverflow(residentBytes)
            value.residentBytes = sum.overflow ? UInt64.max : sum.partialValue
            grouped[identifier] = value
        }

        return grouped.map { identifier, value in
            let displayName = URL(fileURLWithPath: value.bundlePath)
                .deletingPathExtension()
                .lastPathComponent
            return FamilyGroup(
                identifier: identifier,
                displayName: displayName,
                bundlePath: value.bundlePath,
                processes: value.processes.sorted { $0.identity.pid < $1.identity.pid },
                residentBytes: value.residentBytes
            )
        }
    }

    private func applicationBundlePath(forExecutablePath path: String) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let lower = standardized.lowercased()
        guard let marker = lower.range(of: ".app/contents/") else { return nil }
        let appEndInLower = lower.index(marker.lowerBound, offsetBy: 4)
        let distance = lower.distance(from: lower.startIndex, to: appEndInLower)
        let appEnd = standardized.index(standardized.startIndex, offsetBy: distance)
        return String(standardized[..<appEnd])
    }

    private func canonicalBundleIdentifier(_ bundlePath: String) -> String {
        return URL(fileURLWithPath: bundlePath)
            .standardizedFileURL
            .path
            .lowercased()
    }

    private func isAllowedApplicationBundlePath(_ bundlePath: String) -> Bool {
        let canonical = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let lower = canonical.lowercased()

        if lower.hasPrefix("/system/") ||
            lower.hasPrefix("/usr/") ||
            lower.hasPrefix("/bin/") ||
            lower.hasPrefix("/sbin/") ||
            lower.hasPrefix("/private/") {
            return false
        }

        if lower.contains("/catalinaperformance.app") {
            return false
        }

        return canonical.hasPrefix("/Applications/") || canonical.hasPrefix("/Users/")
    }
}
