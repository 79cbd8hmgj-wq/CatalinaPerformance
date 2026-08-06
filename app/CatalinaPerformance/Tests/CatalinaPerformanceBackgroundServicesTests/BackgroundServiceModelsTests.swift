import XCTest
@testable import CatalinaPerformanceBackgroundServicesCore

final class BackgroundServiceModelsTests: XCTestCase {
    func testAutomaticCategoriesAreStableAndICloudDriveIsOptional() {
        XCTAssertEqual(BackgroundServiceCategory.automatic, [
            .softwareUpdate,
            .appStoreUpdates,
            .photos,
            .mail,
            .messagesFaceTime,
            .siriSpeech
        ])
        XCTAssertFalse(BackgroundServiceCategory.automatic.contains(.iCloudDrive))
    }

    func testSessionRoundTripPreservesOutstandingRestoreState() throws {
        let record = BackgroundServiceSessionRecord(
            sessionIdentifier: "session-1",
            requestingUID: 501,
            startedAt: Date(timeIntervalSince1970: 90),
            completedAt: nil,
            categories: [
                BackgroundServiceCategoryRecord(
                    category: .photos,
                    requested: true,
                    state: .restoreFailed,
                    note: "Worker identity changed before restoration.",
                    workers: [],
                    userResume: nil,
                    updatedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BackgroundServiceSessionRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.hasOutstandingRestoration)
    }

    func testRestoredAndNotConfiguredCategoriesHaveNoOutstandingRestoration() {
        let record = BackgroundServiceSessionRecord(
            sessionIdentifier: "session-2",
            requestingUID: 501,
            startedAt: Date(timeIntervalSince1970: 90),
            completedAt: Date(timeIntervalSince1970: 120),
            categories: [
                BackgroundServiceCategoryRecord(
                    category: .softwareUpdate,
                    requested: true,
                    state: .restored,
                    note: nil,
                    workers: [],
                    userResume: nil,
                    updatedAt: Date(timeIntervalSince1970: 120)
                ),
                BackgroundServiceCategoryRecord(
                    category: .iCloudDrive,
                    requested: false,
                    state: .notConfigured,
                    note: nil,
                    workers: [],
                    userResume: nil,
                    updatedAt: Date(timeIntervalSince1970: 120)
                )
            ]
        )

        XCTAssertFalse(record.hasOutstandingRestoration)
    }

    func testStatusSnapshotRoundTripsWithoutPrivateWorkerDetails() throws {
        let snapshot = BackgroundServiceStatusSnapshot(
            sessionIdentifier: "session-3",
            state: .degraded,
            categories: [
                BackgroundServiceCategoryStatus(
                    category: .siriSpeech,
                    state: .unsupported,
                    note: "No verified Catalina resume trigger.",
                    updatedAt: Date(timeIntervalSince1970: 130)
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 130)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BackgroundServiceStatusSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("executablePath"))
    }
}
