import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class MemoryDesiredStateStoreTests: XCTestCase {
    func testSaveLoadAndGenerationMonotonicity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryDesiredStateStore(directoryURL: root)
        let first = state(generation: 1)

        try store.save(first)
        XCTAssertEqual(try store.load(), first)
        XCTAssertThrowsError(try store.save(first)) { error in
            XCTAssertEqual(error as? MemoryDesiredStateStoreError, .staleGeneration)
        }
        try store.save(state(generation: 2))
        XCTAssertEqual(try store.load()?.generation, 2)
    }

    func testRejectsMoreThanThreeFamilies() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryDesiredStateStore(directoryURL: root)
        let families = (0..<4).map { family(index: $0) }
        let value = MemoryDesiredState(
            sessionIdentifier: "session",
            requestingUID: 501,
            generation: 1,
            shouldStopAndRestore: false,
            families: families
        )

        XCTAssertThrowsError(try store.save(value)) { error in
            XCTAssertEqual(error as? MemoryDesiredStateStoreError, .unsafeDesiredState)
        }
    }

    func testAgentValidationRejectsWrongOwner() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("Library/Application Support/CatalinaPerformance/memory_management", isDirectory: true)
        let metadata = FixedMetadataProvider(metadata: AppPriorityFileMetadata(
            ownerUID: 502,
            mode: 0o600,
            size: 256,
            isRegularFile: true,
            isDirectory: false,
            isSymbolicLink: false
        ))
        let store = MemoryDesiredStateStore(directoryURL: directory, metadataProvider: metadata)
        try store.save(state(generation: 1))

        XCTAssertThrowsError(try store.loadValidatedForAgent(requestingUID: 501, consoleUID: 501, expectedHomeDirectory: home)) { error in
            XCTAssertEqual(error as? MemoryDesiredStateStoreError, .wrongOwner)
        }
    }

    func testStopAndRestoreStateMustHaveNoFamilies() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryDesiredStateStore(directoryURL: root)
        let value = MemoryDesiredState(
            sessionIdentifier: "session",
            requestingUID: 501,
            generation: 1,
            shouldStopAndRestore: true,
            families: [family(index: 0)]
        )

        XCTAssertNoThrow(try store.save(value))
    }

    private func state(generation: UInt64) -> MemoryDesiredState {
        return MemoryDesiredState(
            sessionIdentifier: "session",
            requestingUID: 501,
            generation: generation,
            shouldStopAndRestore: false,
            families: [family(index: 0)]
        )
    }

    private func family(index: Int) -> MemoryDesiredFamily {
        let bundle = "/Applications/App\(index).app"
        let identity = AppPriorityProcessIdentity(
            pid: Int32(100 + index),
            parentPID: 1,
            effectiveUID: 501,
            executablePath: bundle + "/Contents/MacOS/App\(index)",
            startSeconds: 1000 + Int64(index),
            startMicroseconds: 0,
            processName: "App\(index)",
            niceValue: 0
        )
        let identifier = bundle.lowercased()
        return MemoryDesiredFamily(
            identifier: identifier,
            displayName: "App\(index)",
            bundlePath: bundle,
            processes: [MemoryDesiredProcess(identity: identity, familyIdentifier: identifier, requestedNiceValue: 5)]
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct FixedMetadataProvider: AppPriorityFileMetadataProviding {
    let metadata: AppPriorityFileMetadata
    func metadata(at url: URL) throws -> AppPriorityFileMetadata { return metadata }
}
