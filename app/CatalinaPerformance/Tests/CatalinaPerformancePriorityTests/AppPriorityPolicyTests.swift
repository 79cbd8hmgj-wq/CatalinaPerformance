import XCTest
@testable import CatalinaPerformancePriorityCore

final class AppPriorityPolicyTests: XCTestCase {
    private let firefox = AppPriorityApplication(
        displayName: "Firefox",
        bundleIdentifier: "org.mozilla.firefox",
        bundlePath: "/Applications/Firefox.app",
        executablePath: "/Applications/Firefox.app/Contents/MacOS/firefox"
    )

    private let encoder = AppPriorityApplication(
        displayName: "Encoder",
        bundleIdentifier: "local.encoder",
        bundlePath: "/Applications/Encoder.app",
        executablePath: "/Applications/Encoder.app/Contents/MacOS/Encoder"
    )

    func testStableFirefoxUsesFocusedPolicy() {
        let policy = AppPriorityPolicy.policy(for: firefox)
        XCTAssertEqual(policy.kind, .focusedFirefox)
        XCTAssertEqual(policy.targetNiceValue, -1)
        XCTAssertEqual(policy.maximumBoostedCount, 3)
    }

    func testFirefoxDeveloperEditionRemainsMainOnly() {
        let application = AppPriorityApplication(
            displayName: "Firefox Developer Edition",
            bundleIdentifier: "org.mozilla.firefoxdeveloperedition",
            bundlePath: "/Applications/Firefox Developer Edition.app",
            executablePath: "/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox"
        )
        let policy = AppPriorityPolicy.policy(for: application)
        XCTAssertEqual(policy.kind, .mainProcessOnly)
        XCTAssertEqual(policy.targetNiceValue, -2)
        XCTAssertEqual(policy.maximumBoostedCount, 1)
    }

    func testNonBrowserRetainsVerifiedFamilyMinusFive() {
        let policy = AppPriorityPolicy.policy(for: encoder)
        XCTAssertEqual(policy.kind, .verifiedProcessFamily)
        XCTAssertEqual(policy.targetNiceValue, -5)
        XCTAssertNil(policy.maximumBoostedCount)
    }
}
