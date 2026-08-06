import XCTest
@testable import CatalinaPerformanceBackgroundServicesCore

final class CatalinaBackgroundServiceCatalogTests: XCTestCase {
    func testCatalogRejectsProtectedServicesAndWildcardPaths() throws {
        for target in CatalinaBackgroundServiceCatalog.current.targets {
            XCTAssertNoThrow(try BackgroundServiceProtectedPolicy.validate(target: target))
            XCTAssertFalse(target.launchLabel.contains("*"))
            XCTAssertFalse(target.allowedExecutablePaths.isEmpty)
            XCTAssertTrue(target.allowedExecutablePaths.allSatisfy {
                $0.hasPrefix("/") && !$0.contains("*") && !$0.contains("//")
            })
        }
    }

    func testEveryAutomaticCategoryIsVerifiedOrExplicitlyUnsupported() {
        for category in BackgroundServiceCategory.automatic {
            XCTAssertTrue(
                CatalinaBackgroundServiceCatalog.current.targets.contains(where: { $0.category == category }) ||
                CatalinaBackgroundServiceCatalog.current.unsupportedCategories.contains(category)
            )
        }
    }

    func testCatalogUsesOnlyProbeVerifiedTargetIdentities() throws {
        let fixtureURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/catalina-10.15.7-service-probe.txt")
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
            .replacingOccurrences(of: "Support//cloudphotod", with: "Support/cloudphotod")

        for target in CatalinaBackgroundServiceCatalog.current.targets {
            XCTAssertTrue(fixture.contains("--- SERVICE \(target.launchLabel) ---"))
            XCTAssertTrue(fixture.contains("\"Label\" => \"\(target.launchLabel)\"") || target.mechanism == .settings)
            for path in target.allowedExecutablePaths {
                XCTAssertTrue(fixture.contains(path), "Fixture did not prove path: \(path)")
            }
            for identifier in target.associatedBundleIdentifiers {
                XCTAssertTrue(fixture.contains("bundle_identifier=\(identifier)"), "Fixture did not prove app identifier: \(identifier)")
            }
        }
    }

    func testSiriAndICloudDriveRemainUnsupportedWithoutReliableResumeTrigger() {
        XCTAssertTrue(CatalinaBackgroundServiceCatalog.current.unsupportedCategories.contains(.siriSpeech))
        XCTAssertTrue(CatalinaBackgroundServiceCatalog.current.unsupportedCategories.contains(.iCloudDrive))
        XCTAssertTrue(CatalinaBackgroundServiceCatalog.current.targets(for: .siriSpeech).isEmpty)
        XCTAssertTrue(CatalinaBackgroundServiceCatalog.current.targets(for: .iCloudDrive).isEmpty)
    }

    func testSettingsAndWorkerTargetsAreSeparated() {
        XCTAssertEqual(CatalinaBackgroundServiceCatalog.current.targets(for: .softwareUpdate).map { $0.mechanism }, [.settings])
        XCTAssertEqual(CatalinaBackgroundServiceCatalog.current.targets(for: .appStoreUpdates).map { $0.mechanism }, [.settings])
        XCTAssertTrue(CatalinaBackgroundServiceCatalog.current.workerTargets(for: .photos).allSatisfy { $0.mechanism == .verifiedUserProcessTermination })
    }

    func testProtectedPolicyRejectsCriticalServices() {
        let protected = [
            ("com.apple.securityd", "/usr/sbin/securityd"),
            ("com.apple.trustd", "/usr/libexec/trustd"),
            ("com.apple.accountsd", "/System/Library/Frameworks/Accounts.framework/Versions/A/Support/accountsd"),
            ("com.apple.cloudd", "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd"),
            ("com.apple.ReportCrash", "/System/Library/CoreServices/ReportCrash"),
            ("com.apple.Finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        ]

        for pair in protected {
            let target = BackgroundServiceTarget(
                category: .photos,
                launchLabel: pair.0,
                allowedExecutablePaths: [pair.1],
                associatedBundleIdentifiers: ["com.apple.Photos"],
                mechanism: .verifiedUserProcessTermination
            )
            XCTAssertThrowsError(try BackgroundServiceProtectedPolicy.validate(target: target))
        }
    }
}
