import XCTest
@testable import CatalinaPerformanceBackgroundServicesCore

final class BackgroundServiceSettingsStatusTests: XCTestCase {
    func testLoadsKnownCategoryStatuses() throws {
        let url = try temporaryFile(contents: """
        {"schemaVersion":1,"categories":[
          {"category":"softwareUpdate","state":"paused","note":"Paused"},
          {"category":"appStoreUpdates","state":"restored","note":null}
        ]}
        """)
        let status = try BackgroundServiceSettingsStatus.load(from: url)
        XCTAssertEqual(status.categories, [
            BackgroundServiceSettingsCategoryStatus(category: .softwareUpdate, state: .paused, note: "Paused"),
            BackgroundServiceSettingsCategoryStatus(category: .appStoreUpdates, state: .restored, note: nil)
        ])
    }

    func testRejectsUnknownCategoryAndSchema() throws {
        let unknown = try temporaryFile(contents: "{\"schemaVersion\":1,\"categories\":[{\"category\":\"other\",\"state\":\"paused\",\"note\":null}]}")
        XCTAssertThrowsError(try BackgroundServiceSettingsStatus.load(from: unknown))
        let schema = try temporaryFile(contents: "{\"schemaVersion\":2,\"categories\":[]}")
        XCTAssertThrowsError(try BackgroundServiceSettingsStatus.load(from: schema))
    }

    func testRejectsOversizedAndSymbolicLinkFiles() throws {
        let oversized = try temporaryFile(data: Data(repeating: 65, count: BackgroundServiceSettingsStatus.maximumFileSize + 1))
        XCTAssertThrowsError(try BackgroundServiceSettingsStatus.load(from: oversized))

        let target = try temporaryFile(contents: "{\"schemaVersion\":1,\"categories\":[]}")
        let link = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try BackgroundServiceSettingsStatus.load(from: link))
    }

    private func temporaryFile(contents: String) throws -> URL {
        return try temporaryFile(data: Data(contents.utf8))
    }

    private func temporaryFile(data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("status.json")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }
}
