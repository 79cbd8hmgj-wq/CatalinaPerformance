import XCTest
@testable import CatalinaPerformancePriorityCore

final class AppPriorityProcessFamilyTests: XCTestCase {
    private let firefox = AppPriorityApplication(
        displayName: "Firefox",
        bundleIdentifier: "org.mozilla.firefox",
        bundlePath: "/Applications/Firefox.app",
        executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox"
    )

    private func process(pid: Int32, ppid: Int32, uid: UInt32 = 501, path: String, start: Int64 = 100, name: String = "process", nice: Int32 = 0) -> AppPriorityProcessIdentity {
        AppPriorityProcessIdentity(pid: pid, parentPID: ppid, effectiveUID: uid, executablePath: path, startSeconds: start, startMicroseconds: 0, processName: name, niceValue: nice)
    }

    func testIncludesRecursiveDescendantsAndDetachedInBundleHelpers() {
        let main = process(pid: 100, ppid: 1, path: firefox.executablePath, name: "firefox")
        let child = process(pid: 101, ppid: 100, path: "/usr/libexec/firefox-child")
        let grandchild = process(pid: 102, ppid: 101, path: "/usr/libexec/firefox-grandchild")
        let detached = process(pid: 200, ppid: 1, path: "/Applications/Firefox.app/Contents/Frameworks/Firefox Helper.app/Contents/MacOS/Firefox Helper")
        let unrelated = process(pid: 300, ppid: 1, path: "/tmp/Firefox Helper")
        let result = AppPriorityProcessFamilyResolver.resolve(application: firefox, requestingUID: 501, processes: [main, child, grandchild, detached, unrelated])
        XCTAssertEqual(Set(result.eligible.map { $0.pid }), [100, 101, 102, 200])
        XCTAssertFalse(result.eligible.contains { $0.pid == unrelated.pid })
        XCTAssertTrue(result.mainProcessFound)
    }

    func testMainProcessOnlyScopeExcludesChildrenAndDetachedHelpers() {
        let main = process(pid: 100, ppid: 1, path: firefox.executablePath, name: "firefox")
        let child = process(pid: 101, ppid: 100, path: "/usr/libexec/firefox-child")
        let detached = process(pid: 200, ppid: 1, path: "/Applications/Firefox.app/Contents/Frameworks/Firefox Helper.app/Contents/MacOS/Firefox Helper")

        let result = AppPriorityProcessFamilyResolver.resolve(
            application: firefox,
            requestingUID: 501,
            processes: [main, child, detached],
            policyKind: .mainProcessOnly
        )

        XCTAssertEqual(result.eligible.map { $0.pid }, [100])
        XCTAssertTrue(result.mainProcessFound)
    }

    func testRejectsRootOtherUserAndCriticalProcessesEvenWhenAssociated() {
        let main = process(pid: 100, ppid: 1, path: firefox.executablePath, name: "firefox")
        let rootChild = process(pid: 101, ppid: 100, uid: 0, path: "/usr/bin/root-helper")
        let otherUser = process(pid: 102, ppid: 100, uid: 502, path: "/usr/bin/other")
        let finder = process(pid: 103, ppid: 100, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", name: "Finder")
        let result = AppPriorityProcessFamilyResolver.resolve(application: firefox, requestingUID: 501, processes: [main, rootChild, otherUser, finder])
        XCTAssertEqual(result.eligible.map { $0.pid }, [100])
        XCTAssertEqual(result.skipped.map { $0.pid }, [103])
    }

    func testIdentityMismatchDetectsPidReuseButIgnoresParentChange() {
        let original = process(pid: 42, ppid: 1, path: "/Applications/TextEdit.app/Contents/MacOS/TextEdit", start: 100)
        let reused = process(pid: 42, ppid: 1, path: original.executablePath, start: 200)
        let reparented = process(pid: 42, ppid: 999, path: original.executablePath, start: 100)
        XCTAssertFalse(original.matchesForMutation(reused))
        XCTAssertTrue(original.matchesForMutation(reparented))
    }

    func testNoMainProcessStillAllowsVerifiedDetachedHelperButReportsWaiting() {
        let detached = process(pid: 200, ppid: 1, path: "/Applications/Firefox.app/Contents/XPCServices/Firefox Helper.app/Contents/MacOS/Firefox Helper")
        let result = AppPriorityProcessFamilyResolver.resolve(application: firefox, requestingUID: 501, processes: [detached])
        XCTAssertEqual(result.eligible.map { $0.pid }, [200])
        XCTAssertFalse(result.mainProcessFound)
    }

    func testFocusedFirefoxReturnsFullTrackedFamilyWithoutDefiningMutationSet() {
        let main = process(pid: 100, ppid: 1, path: firefox.executablePath, name: "firefox")
        let child = process(pid: 101, ppid: 100, path: "/Applications/Firefox.app/Contents/MacOS/plugin-container", name: "plugin-container")
        let detached = process(pid: 200, ppid: 1, path: "/Applications/Firefox.app/Contents/MacOS/gpu-helper", name: "Firefox GPU Helper")

        let result = AppPriorityProcessFamilyResolver.resolve(
            application: firefox,
            requestingUID: 501,
            processes: [main, child, detached],
            policyKind: .focusedFirefox
        )

        XCTAssertEqual(result.eligible.map { $0.pid }, [100, 101, 200])
        XCTAssertTrue(result.mainProcessFound)
    }
}
