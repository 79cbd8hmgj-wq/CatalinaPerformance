import XCTest
@testable import CatalinaPerformancePriorityCore

final class FocusedFirefoxProcessClassifierTests: XCTestCase {
    private let firefox = AppPriorityApplication(
        displayName: "Firefox",
        bundleIdentifier: "org.mozilla.firefox",
        bundlePath: "/Applications/Firefox.app",
        executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox"
    )

    private let pluginContainer = "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
    private let gpuHelper = "/Applications/Firefox.app/Contents/MacOS/gpu-helper.app/Contents/MacOS/Firefox GPU Helper"

    private func process(
        pid: Int32,
        ppid: Int32,
        uid: UInt32 = 501,
        path: String,
        name: String
    ) -> AppPriorityProcessIdentity {
        return AppPriorityProcessIdentity(
            pid: pid,
            parentPID: ppid,
            effectiveUID: uid,
            executablePath: path,
            startSeconds: Int64(pid),
            startMicroseconds: 0,
            processName: name,
            niceValue: 0
        )
    }

    func testClassifiesCapturedFirefoxRolesAndExcludesInfrastructure() {
        let parent = process(pid: 612, ppid: 1, path: firefox.executablePath, name: "firefox")
        let socket = process(pid: 615, ppid: 612, path: pluginContainer, name: "plugin-container")
        let gpu = process(pid: 616, ppid: 612, path: gpuHelper, name: "Firefox GPU Helper")
        let content = process(pid: 844, ppid: 612, path: pluginContainer, name: "plugin-container")
        let rdd = process(pid: 621, ppid: 612, path: pluginContainer, name: "plugin-container")
        let utility = process(pid: 737, ppid: 612, path: pluginContainer, name: "plugin-container")
        let preallocated = process(pid: 20025, ppid: 612, path: pluginContainer, name: "plugin-container")

        let result = FocusedFirefoxProcessClassifier.classify(
            application: firefox,
            requestingUID: 501,
            processes: [parent, socket, gpu, content, rdd, utility, preallocated],
            argumentsByPID: [
                612: [firefox.executablePath, "-foreground"],
                615: [pluginContainer, "1", "socket"],
                616: [gpuHelper, "2", "gpu"],
                844: [pluginContainer, "-isForBrowser", "63", "tab"],
                621: [pluginContainer, "4", "rdd"],
                737: [pluginContainer, "24", "utility"],
                20025: [pluginContainer, "-isForBrowser", "144", "tab"]
            ]
        )

        XCTAssertEqual(result.parent?.pid, 612)
        XCTAssertEqual(result.gpu?.pid, 616)
        XCTAssertEqual(Set(result.contentStyle.map { $0.pid }), [844, 20025])
        let contentPIDs = Set(result.contentStyle.map { $0.pid })
        XCTAssertFalse(contentPIDs.contains(615))
        XCTAssertFalse(contentPIDs.contains(621))
        XCTAssertFalse(contentPIDs.contains(737))
        XCTAssertEqual(result.trackedProcessCount, 7)
        XCTAssertEqual(result.skippedCount, 0)
    }

    func testRejectsWrongUIDAndOutsideBundleTargets() {
        let parent = process(pid: 612, ppid: 1, path: firefox.executablePath, name: "firefox")
        let wrongUID = process(pid: 700, ppid: 612, uid: 502, path: pluginContainer, name: "plugin-container")
        let outside = process(pid: 701, ppid: 612, path: "/tmp/plugin-container", name: "plugin-container")

        let result = FocusedFirefoxProcessClassifier.classify(
            application: firefox,
            requestingUID: 501,
            processes: [parent, wrongUID, outside],
            argumentsByPID: [
                612: [firefox.executablePath, "-foreground"],
                700: [pluginContainer, "-isForBrowser", "1", "tab"],
                701: ["/tmp/plugin-container", "-isForBrowser", "2", "tab"]
            ]
        )

        XCTAssertTrue(result.contentStyle.isEmpty)
        XCTAssertEqual(result.parent?.pid, 612)
    }

    func testRequiresDirectParentForGpuAndContent() {
        let parent = process(pid: 612, ppid: 1, path: firefox.executablePath, name: "firefox")
        let intermediate = process(pid: 650, ppid: 612, path: pluginContainer, name: "plugin-container")
        let nestedGPU = process(pid: 616, ppid: 650, path: gpuHelper, name: "Firefox GPU Helper")
        let nestedContent = process(pid: 844, ppid: 650, path: pluginContainer, name: "plugin-container")

        let result = FocusedFirefoxProcessClassifier.classify(
            application: firefox,
            requestingUID: 501,
            processes: [parent, intermediate, nestedGPU, nestedContent],
            argumentsByPID: [
                612: [firefox.executablePath, "-foreground"],
                650: [pluginContainer, "1", "socket"],
                616: [gpuHelper, "2", "gpu"],
                844: [pluginContainer, "-isForBrowser", "63", "tab"]
            ]
        )

        XCTAssertNil(result.gpu)
        XCTAssertTrue(result.contentStyle.isEmpty)
    }

    func testContentRequiresIsForBrowserAndTabRole() {
        let parent = process(pid: 612, ppid: 1, path: firefox.executablePath, name: "firefox")
        let missingFlag = process(pid: 700, ppid: 612, path: pluginContainer, name: "plugin-container")
        let wrongRole = process(pid: 701, ppid: 612, path: pluginContainer, name: "plugin-container")

        let result = FocusedFirefoxProcessClassifier.classify(
            application: firefox,
            requestingUID: 501,
            processes: [parent, missingFlag, wrongRole],
            argumentsByPID: [
                612: [firefox.executablePath, "-foreground"],
                700: [pluginContainer, "3", "tab"],
                701: [pluginContainer, "-isForBrowser", "4", "utility"]
            ]
        )

        XCTAssertTrue(result.contentStyle.isEmpty)
    }

    func testAmbiguousParentAndGpuRolesAreNotTargeted() {
        let parentA = process(pid: 612, ppid: 1, path: firefox.executablePath, name: "firefox")
        let parentB = process(pid: 613, ppid: 1, path: firefox.executablePath, name: "firefox")
        let gpuA = process(pid: 616, ppid: 612, path: gpuHelper, name: "Firefox GPU Helper")
        let gpuB = process(pid: 617, ppid: 612, path: gpuHelper, name: "Firefox GPU Helper")

        let result = FocusedFirefoxProcessClassifier.classify(
            application: firefox,
            requestingUID: 501,
            processes: [parentA, parentB, gpuA, gpuB],
            argumentsByPID: [
                612: [firefox.executablePath, "-foreground"],
                613: [firefox.executablePath, "-foreground"],
                616: [gpuHelper, "2", "gpu"],
                617: [gpuHelper, "3", "gpu"]
            ]
        )

        XCTAssertNil(result.parent)
        XCTAssertNil(result.gpu)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testProcessNameAloneCannotVerifyHelperRole() {
        let parent = process(pid: 612, ppid: 1, path: firefox.executablePath, name: "firefox")
        let fake = process(pid: 616, ppid: 612, path: "/tmp/Fake GPU", name: "Firefox GPU Helper")

        let result = FocusedFirefoxProcessClassifier.classify(
            application: firefox,
            requestingUID: 501,
            processes: [parent, fake],
            argumentsByPID: [
                612: [firefox.executablePath, "-foreground"],
                616: ["/tmp/Fake GPU", "2", "gpu"]
            ]
        )

        XCTAssertNil(result.gpu)
    }
}
