import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class MemoryProcessFamilyAnalyzerTests: XCTestCase {
    private let uid: UInt32 = 501
    private let physicalBytes: UInt64 = 4_294_967_296

    func testSameUserProcessesInSameBundleAreGrouped() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let processes = [
            process(pid: 10, parent: 1, path: "/Applications/Browser.app/Contents/MacOS/Browser"),
            process(pid: 11, parent: 10, path: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper")
        ]
        let resources = FakeResources(values: [10: 180 * mib, 11: 120 * mib])
        let frontmost = app(name: "Other", path: "/Applications/Other.app")

        var result: [MemoryProcessFamilyCandidate] = []
        for _ in 0..<3 {
            result = analyzer.rankEligibleFamilies(
                processes: processes,
                currentUID: uid,
                physicalBytes: physicalBytes,
                frontmostApplication: frontmost,
                appPriorityApplication: nil,
                resourceInspector: resources
            )
        }

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].processes.count, 2)
        XCTAssertEqual(result[0].residentBytes, 300 * mib)
    }

    func testFamilyRequiresThreeBackgroundSamples() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let processes = [process(pid: 10, parent: 1, path: "/Applications/Browser.app/Contents/MacOS/Browser")]
        let resources = FakeResources(values: [10: 300 * mib])
        let frontmost = app(name: "Other", path: "/Applications/Other.app")

        let first = analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: frontmost, appPriorityApplication: nil, resourceInspector: resources)
        let second = analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: frontmost, appPriorityApplication: nil, resourceInspector: resources)
        let third = analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: frontmost, appPriorityApplication: nil, resourceInspector: resources)

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(third.count, 1)
    }

    func testFrontmostFamilyIsExcludedAndMustRestabilize() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let processes = [process(pid: 10, parent: 1, path: "/Applications/Browser.app/Contents/MacOS/Browser")]
        let resources = FakeResources(values: [10: 300 * mib])
        let browser = app(name: "Browser", path: "/Applications/Browser.app")
        let other = app(name: "Other", path: "/Applications/Other.app")

        for _ in 0..<3 {
            _ = analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources)
        }
        XCTAssertTrue(analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: browser, appPriorityApplication: nil, resourceInspector: resources).isEmpty)
        XCTAssertTrue(analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources).isEmpty)
        XCTAssertTrue(analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources).isEmpty)
        XCTAssertEqual(analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources).count, 1)
    }

    func testAppPriorityTargetIsExcluded() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let processes = [process(pid: 10, parent: 1, path: "/Applications/Browser.app/Contents/MacOS/Browser")]
        let resources = FakeResources(values: [10: 300 * mib])
        let other = app(name: "Other", path: "/Applications/Other.app")
        let priority = app(name: "Browser", path: "/Applications/Browser.app")

        for _ in 0..<4 {
            let result = analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: priority, resourceInspector: resources)
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testRootOwnedProcessIsExcluded() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let root = process(pid: 10, parent: 1, uid: 0, path: "/Applications/Browser.app/Contents/MacOS/Browser")
        let resources = FakeResources(values: [10: 500 * mib])
        let other = app(name: "Other", path: "/Applications/Other.app")

        for _ in 0..<3 {
            let result = analyzer.rankEligibleFamilies(processes: [root], currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources)
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testProtectedSystemPathIsExcluded() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let finder = process(pid: 10, parent: 1, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", name: "Finder")
        let resources = FakeResources(values: [10: 500 * mib])
        let other = app(name: "Other", path: "/Applications/Other.app")

        for _ in 0..<3 {
            let result = analyzer.rankEligibleFamilies(processes: [finder], currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources)
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testMinimumSignificanceIsMaxOf256MiBAndFivePercent() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let low = process(pid: 10, parent: 1, path: "/Applications/Small.app/Contents/MacOS/Small")
        let resources = FakeResources(values: [10: 255 * mib])
        let other = app(name: "Other", path: "/Applications/Other.app")

        for _ in 0..<4 {
            XCTAssertTrue(analyzer.rankEligibleFamilies(processes: [low], currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources).isEmpty)
        }
    }

    func testMemoryGrowthBreaksTieDeterministically() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let a = process(pid: 10, parent: 1, path: "/Applications/A.app/Contents/MacOS/A")
        let b = process(pid: 20, parent: 1, path: "/Applications/B.app/Contents/MacOS/B")
        let resources = MutableFakeResources(values: [10: 280 * mib, 20: 300 * mib])
        let other = app(name: "Other", path: "/Applications/Other.app")

        _ = analyzer.rankEligibleFamilies(processes: [a, b], currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources)
        resources.values = [10: 300 * mib, 20: 300 * mib]
        _ = analyzer.rankEligibleFamilies(processes: [a, b], currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources)
        let ranked = analyzer.rankEligibleFamilies(processes: [a, b], currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources)

        XCTAssertEqual(ranked.map { $0.displayName }, ["A", "B"])
    }

    func testMaximumThreeFamiliesAreReturned() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let processes = (0..<5).map { index in
            process(pid: Int32(10 + index), parent: 1, path: "/Applications/App\(index).app/Contents/MacOS/App\(index)")
        }
        let resources = FakeResources(values: Dictionary(uniqueKeysWithValues: processes.enumerated().map { index, process in
            (process.pid, UInt64(400 - index * 10) * mib)
        }))
        let other = app(name: "Other", path: "/Applications/Other.app")

        var result: [MemoryProcessFamilyCandidate] = []
        for _ in 0..<3 {
            result = analyzer.rankEligibleFamilies(processes: processes, currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: other, appPriorityApplication: nil, resourceInspector: resources)
        }

        XCTAssertEqual(result.count, 3)
    }

    func testMissingFrontmostIdentityAdmitsNoNewFamilies() {
        var analyzer = MemoryProcessFamilyAnalyzer()
        let processValue = process(pid: 10, parent: 1, path: "/Applications/Browser.app/Contents/MacOS/Browser")
        let resources = FakeResources(values: [10: 300 * mib])

        for _ in 0..<4 {
            XCTAssertTrue(analyzer.rankEligibleFamilies(processes: [processValue], currentUID: uid, physicalBytes: physicalBytes, frontmostApplication: nil, appPriorityApplication: nil, resourceInspector: resources).isEmpty)
        }
    }

    private var mib: UInt64 { 1_048_576 }

    private func process(pid: Int32, parent: Int32, uid: UInt32 = 501, path: String, name: String? = nil) -> AppPriorityProcessIdentity {
        return AppPriorityProcessIdentity(
            pid: pid,
            parentPID: parent,
            effectiveUID: uid,
            executablePath: path,
            startSeconds: Int64(pid) * 10,
            startMicroseconds: 0,
            processName: name ?? URL(fileURLWithPath: path).lastPathComponent,
            niceValue: 0
        )
    }

    private func app(name: String, path: String) -> AppPriorityApplication {
        return AppPriorityApplication(
            displayName: name,
            bundleIdentifier: "test.\(name.lowercased())",
            bundlePath: path,
            executablePath: path + "/Contents/MacOS/" + name
        )
    }
}

private final class FakeResources: AppPriorityProcessResourceInspecting {
    let values: [Int32: UInt64]
    init(values: [Int32: UInt64]) { self.values = values }
    func residentBytes(pid: Int32) throws -> UInt64 { return values[pid] ?? 0 }
}

private final class MutableFakeResources: AppPriorityProcessResourceInspecting {
    var values: [Int32: UInt64]
    init(values: [Int32: UInt64]) { self.values = values }
    func residentBytes(pid: Int32) throws -> UInt64 { return values[pid] ?? 0 }
}
