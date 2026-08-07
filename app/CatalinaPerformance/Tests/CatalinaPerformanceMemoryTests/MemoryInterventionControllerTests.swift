import XCTest
import CatalinaPerformancePriorityCore
@testable import CatalinaPerformanceMemoryCore

final class MemoryInterventionControllerTests: XCTestCase {
    func testZeroNiceAppliesFiveAndRestoresZero() throws {
        let harness = makeHarness(initialNice: [10: 0])
        _ = try harness.controller.reconcile(desired: desired(generation: 1, pids: [10]))
        XCTAssertEqual(harness.mutator.values[10], 5)

        _ = try harness.controller.restoreAll()
        XCTAssertEqual(harness.mutator.values[10], 0)
    }

    func testPositiveNiceTwoRestoresExactly() throws {
        let harness = makeHarness(initialNice: [10: 2])
        _ = try harness.controller.reconcile(desired: desired(generation: 1, pids: [10]))
        XCTAssertEqual(harness.mutator.values[10], 5)
        _ = try harness.controller.restoreAll()
        XCTAssertEqual(harness.mutator.values[10], 2)
    }

    func testExistingNiceEightIsNotRaisedOrLowered() throws {
        let harness = makeHarness(initialNice: [10: 8])
        _ = try harness.controller.reconcile(desired: desired(generation: 1, pids: [10]))
        XCTAssertEqual(harness.mutator.values[10], 8)
        XCTAssertTrue(harness.mutator.setEvents.isEmpty)
    }

    func testNegativeNiceRestoresExactly() throws {
        let harness = makeHarness(initialNice: [10: -5])
        _ = try harness.controller.reconcile(desired: desired(generation: 1, pids: [10]))
        XCTAssertEqual(harness.mutator.values[10], 5)
        _ = try harness.controller.restoreAll()
        XCTAssertEqual(harness.mutator.values[10], -5)
    }

    func testIdentityMismatchRefusesRestore() throws {
        let harness = makeHarness(initialNice: [10: 0])
        _ = try harness.controller.reconcile(desired: desired(generation: 1, pids: [10]))
        harness.inspector.values[10] = identity(pid: 10, startSeconds: 999)

        let outcome = try harness.controller.restoreAll()

        XCTAssertEqual(harness.mutator.values[10], 5)
        XCTAssertEqual(outcome.outstandingRestorationCount, 1)
    }

    func testStateSaveFailureOccursBeforePriorityWrite() {
        let inspector = FakeProcessInspector(values: [10: identity(pid: 10)])
        let mutator = FakePriorityMutator(values: [10: 0])
        let store = FakeAgentStateStore()
        store.failWrites = true
        let controller = MemoryInterventionController(
            inspector: inspector,
            mutator: mutator,
            stateStore: store,
            requestingUID: 501,
            nowProvider: { Date(timeIntervalSince1970: 100) }
        )

        XCTAssertThrowsError(try controller.reconcile(desired: desired(generation: 1, pids: [10])))
        XCTAssertTrue(mutator.setEvents.isEmpty)
    }

    func testRemovedFamilyRestoresBeforeReplacementApplies() throws {
        let inspector = FakeProcessInspector(values: [
            10: identity(pid: 10, bundleName: "A"),
            20: identity(pid: 20, bundleName: "B")
        ])
        let mutator = FakePriorityMutator(values: [10: 0, 20: 0])
        let store = FakeAgentStateStore()
        let controller = MemoryInterventionController(
            inspector: inspector,
            mutator: mutator,
            stateStore: store,
            requestingUID: 501,
            nowProvider: { Date(timeIntervalSince1970: 100) }
        )

        _ = try controller.reconcile(desired: desired(generation: 1, pids: [10], bundleNames: ["A"]))
        _ = try controller.reconcile(desired: desired(generation: 2, pids: [20], bundleNames: ["B"]))

        XCTAssertEqual(mutator.setEvents, [
            PriorityEvent(pid: 10, value: 5),
            PriorityEvent(pid: 10, value: 0),
            PriorityEvent(pid: 20, value: 5)
        ])
    }

    func testMoreThanThreeFamiliesIsRejected() {
        let values = Dictionary(uniqueKeysWithValues: (10...13).map { pid in
            (Int32(pid), identity(pid: Int32(pid), bundleName: "App\(pid)"))
        })
        let inspector = FakeProcessInspector(values: values)
        let mutator = FakePriorityMutator(values: Dictionary(uniqueKeysWithValues: values.keys.map { ($0, 0) }))
        let store = FakeAgentStateStore()
        let controller = MemoryInterventionController(inspector: inspector, mutator: mutator, stateStore: store, requestingUID: 501)
        let state = desired(
            generation: 1,
            pids: [10, 11, 12, 13],
            bundleNames: ["App10", "App11", "App12", "App13"]
        )

        XCTAssertThrowsError(try controller.reconcile(desired: state)) { error in
            XCTAssertEqual(error as? MemoryInterventionError, .invalidDesiredState)
        }
        XCTAssertTrue(mutator.setEvents.isEmpty)
    }

    private func makeHarness(initialNice: [Int32: Int32]) -> Harness {
        let identities = Dictionary(uniqueKeysWithValues: initialNice.keys.map { ($0, identity(pid: $0)) })
        let inspector = FakeProcessInspector(values: identities)
        let mutator = FakePriorityMutator(values: initialNice)
        let store = FakeAgentStateStore()
        let controller = MemoryInterventionController(
            inspector: inspector,
            mutator: mutator,
            stateStore: store,
            requestingUID: 501,
            nowProvider: { Date(timeIntervalSince1970: 100) }
        )
        return Harness(controller: controller, inspector: inspector, mutator: mutator, store: store)
    }

    private func desired(
        generation: UInt64,
        pids: [Int32],
        bundleNames: [String]? = nil
    ) -> MemoryDesiredState {
        let names = bundleNames ?? pids.map { _ in "App" }
        let families = zip(pids, names).map { pid, name -> MemoryDesiredFamily in
            let id = identity(pid: pid, bundleName: name)
            let bundle = "/Applications/\(name).app"
            let familyID = bundle.lowercased()
            return MemoryDesiredFamily(
                identifier: familyID,
                displayName: name,
                bundlePath: bundle,
                processes: [MemoryDesiredProcess(identity: id, familyIdentifier: familyID, requestedNiceValue: 5)]
            )
        }
        return MemoryDesiredState(
            sessionIdentifier: "session",
            requestingUID: 501,
            generation: generation,
            shouldStopAndRestore: false,
            families: families
        )
    }

    private func identity(
        pid: Int32,
        bundleName: String = "App",
        startSeconds: Int64? = nil
    ) -> AppPriorityProcessIdentity {
        return AppPriorityProcessIdentity(
            pid: pid,
            parentPID: 1,
            effectiveUID: 501,
            executablePath: "/Applications/\(bundleName).app/Contents/MacOS/\(bundleName)",
            startSeconds: startSeconds ?? Int64(pid) * 10,
            startMicroseconds: 0,
            processName: bundleName,
            niceValue: 0
        )
    }
}

private struct Harness {
    let controller: MemoryInterventionController
    let inspector: FakeProcessInspector
    let mutator: FakePriorityMutator
    let store: FakeAgentStateStore
}

private final class FakeProcessInspector: AppPriorityProcessInspecting {
    var values: [Int32: AppPriorityProcessIdentity]
    init(values: [Int32: AppPriorityProcessIdentity]) { self.values = values }
    func allProcesses() throws -> [AppPriorityProcessIdentity] { return Array(values.values) }
    func process(pid: Int32) throws -> AppPriorityProcessIdentity {
        guard let value = values[pid] else {
            throw AppPriorityProcessError.readFailed(pid: pid, code: -3)
        }
        return value
    }
}

private struct PriorityEvent: Equatable {
    let pid: Int32
    let value: Int32
}

private final class FakePriorityMutator: AppPriorityPriorityMutating {
    var values: [Int32: Int32]
    var setEvents: [PriorityEvent] = []
    init(values: [Int32: Int32]) { self.values = values }
    func priority(pid: Int32) throws -> Int32 { return values[pid] ?? 0 }
    func setPriority(pid: Int32, value: Int32) throws {
        setEvents.append(PriorityEvent(pid: pid, value: value))
        values[pid] = value
    }
}

private final class FakeAgentStateStore: MemoryAgentStateStoring {
    let paths = MemoryAgentRuntimePaths(runtimeRoot: URL(fileURLWithPath: "/tmp"), requestingUID: 501)
    var state: MemoryAgentRuntimeState?
    var status: MemoryAgentStatus?
    var monitorIdentity: MemoryAgentMonitorIdentity?
    var stop = false
    var failWrites = false

    func prepareDirectories() throws {}
    func writeRuntimeState(_ state: MemoryAgentRuntimeState) throws {
        if failWrites { throw MemoryInterventionError.statePersistenceFailed }
        self.state = state
    }
    func loadRuntimeState() throws -> MemoryAgentRuntimeState {
        guard let state = state else { throw MemoryAgentStateStoreError.corruptState }
        return state
    }
    func runtimeStateIfPresent() -> MemoryAgentRuntimeState? { return state }
    func writeStatus(_ status: MemoryAgentStatus) throws { self.status = status }
    func loadStatus() -> MemoryAgentStatus? { return status }
    func writeMonitorIdentity(_ identity: MemoryAgentMonitorIdentity) throws { monitorIdentity = identity }
    func loadMonitorIdentity() -> MemoryAgentMonitorIdentity? { return monitorIdentity }
    func createStopRequest() throws { stop = true }
    func stopRequested() -> Bool { return stop }
    func clearStopRequest() { stop = false }
    func removeRuntimeFilesAfterSuccessfulRestore() {
        if state?.hasOutstandingRestoration != true { state = nil }
    }
}
