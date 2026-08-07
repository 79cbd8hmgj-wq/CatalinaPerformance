# WindowServer / GPU Pressure Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add read-only WindowServer pressure telemetry to CatalinaPerformance so each Performance Mode session captures a three-sample pre-ON graphics baseline, continuously measures WindowServer CPU pressure every two seconds, classifies sustained pressure, persists the comparison, and reports it in the Session Dashboard without changing graphics settings dynamically.

**Architecture:** Extend `CatalinaPerformanceDashboardCore` rather than creating a separate monitor. WindowServer discovery reuses the existing verified process-inspection boundary from `CatalinaPerformancePriorityCore`; CPU percentage is derived from cumulative CPU-time deltas and wall-clock deltas. Graphics pressure state is recorded as optional additive session data so existing persisted dashboard reports remain decodable. The existing `PerformanceSessionCoordinator` owns the three-sample pre-ON baseline sequence and continues using its current two-second active-session scheduler.

**Tech Stack:** Swift 5 / Swift Package Manager, AppKit, Foundation `DispatchQueue`, existing `CatalinaProcessSupport` native process APIs, XCTest, shell source-contract tests, macOS Catalina 10.15.7 / Xcode 12.4 compatibility.

## Global Constraints

- WindowServer monitoring is read-only telemetry.
- Collect exactly three pre-ON WindowServer samples over approximately four seconds before Performance Mode applies changes.
- Reuse the existing two-second Session Dashboard sampling cadence while Performance Mode is active.
- Capture final pre-restore and post-restore WindowServer readings.
- Classify pressure as Normal, Elevated, High, or Unavailable using both absolute CPU and deviation from baseline.
- Use a three-sample rolling average for classification.
- A High state requires two consecutive High-candidate classifications.
- Never interpret a failed or unverifiable reading as `0%`.
- Monitoring failure must never block Performance Mode ON, OFF, Emergency Restore, shutdown, or restoration.
- Reacquire WindowServer after PID/identity replacement; the replacement interval itself is Unavailable.
- Do not create a new daemon, repeating timer, privileged helper, administrator prompt, or graphics mutation path.
- Do not restart or terminate WindowServer, Finder, Dock, or SystemUIServer.
- Do not change resolution, scaling, refresh rate, calibration, wallpaper, desktop icons, Quartz debug flags, graphics-driver state, or undocumented rendering controls.
- Visual Performance remains the only subsystem that mutates visual preferences.
- Perform process inspection and metric collection off the AppKit main thread; main-thread work is presentation only.
- Preserve macOS Catalina 10.15.7 and Xcode 12.4 compatibility; avoid compact Swift constructs that are known to be fragile on the Catalina compiler.
- Maintain backward compatibility with existing version-1 dashboard JSON by adding graphics data as optional additive fields rather than requiring a schema migration.

---

## File Structure

### Create

- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/WindowServerPressureModels.swift`
  - Owns WindowServer sample identity, pressure classification, baseline/active aggregates, rolling-window logic, and advisory derivation.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/WindowServerMetricsCollector.swift`
  - Owns exact WindowServer discovery, process-identity verification, cumulative CPU-time delta calculation, PID replacement handling, and reset behavior.
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/WindowServerPressureModelsTests.swift`
  - Threshold, rolling-average, High-confirmation, baseline, aggregation, and availability tests.
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/WindowServerMetricsCollectorTests.swift`
  - Discovery, identity, delta, replacement, and failure tests.

### Modify

- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
  - Adds optional WindowServer reading/session data to snapshots, records, and completed reports without breaking old JSON.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift`
  - Injects the WindowServer collector and appends its reading to every session snapshot.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionRecorder.swift`
  - Records graphics baseline samples, active samples, final pre-restore, post-restore, and completed graphics summary.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift`
  - Implements the scheduler-driven 1/3 → 2/3 → 3/3 graphics baseline preparation sequence and keeps monitoring failures non-blocking.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift`
  - Adds preparation progress and active/completed Graphics / WindowServer rows plus neutral advisory copy.
- `app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift`
  - Renders the dedicated Graphics / WindowServer section separately from existing System and Visual Performance sections.
- `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
  - Wires the WindowServer collector into `makePerformanceSessionCoordinator()` only; no new lifecycle owner or timer.
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionMetricModelsTests.swift`
  - Codable/backward-compatibility and aggregate integration tests.
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionMetricsCollectorTests.swift`
  - Snapshot integration and unavailable propagation tests.
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionRecorderTests.swift`
  - Baseline/active/final/post graphics recording tests.
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionCoordinatorTests.swift`
  - Three-sample pre-ON sequence, progress, non-blocking failure, finalization, and scheduler tests.
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionDashboardPresentationTests.swift`
  - Active/completed/preparing rendering tests.
- `scripts/tests/test_session_dashboard_ui_source.sh`
  - Source contract for the dedicated section and no prohibited graphics mutation behavior.
- `docs/GUI_TESTING.md`
  - Adds Catalina runtime smoke steps for WindowServer discovery, active sampling, spike handling, and completed report.
- `docs/TESTING_CHECKLIST.md`
  - Adds regression and restoration checks.

---

### Task 1: Define WindowServer pressure models and deterministic classifier

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/WindowServerPressureModels.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/WindowServerPressureModelsTests.swift`

**Interfaces:**
- Produces:
  - `public enum WindowServerPressureLevel: String, Codable, Equatable { case normal, elevated, high, unavailable }`
  - `public struct WindowServerProcessKey: Codable, Equatable, Hashable`
  - `public struct WindowServerCPUReading: Codable, Equatable`
  - `public struct WindowServerBaselineSummary: Codable, Equatable`
  - `public struct WindowServerSessionAggregate: Codable, Equatable`
  - `public struct WindowServerPressureClassifier`
  - `public mutating func recordActive(_ reading: WindowServerCPUReading, at date: Date)`
  - `public static func classify(rollingCPU: Double?, baselineCPU: Double?, consecutiveHighCandidates: Int) -> WindowServerPressureLevel`

- [ ] **Step 1: Write failing threshold and rolling-average tests**

Create tests that pin the approved boundaries exactly:

```swift
func testNormalRequiresBothAbsoluteAndRelativeConditions() {
    XCTAssertEqual(
        WindowServerPressureClassifier.classify(
            rollingCPU: 14.9,
            baselineCPU: 7.0,
            consecutiveHighCandidates: 0
        ),
        .normal
    )
    XCTAssertEqual(
        WindowServerPressureClassifier.classify(
            rollingCPU: 14.9,
            baselineCPU: 6.8,
            consecutiveHighCandidates: 0
        ),
        .elevated
    )
}

func testElevatedAtFifteenPercent() {
    XCTAssertEqual(
        WindowServerPressureClassifier.classify(
            rollingCPU: 15.0,
            baselineCPU: 10.0,
            consecutiveHighCandidates: 0
        ),
        .elevated
    )
}

func testThirtyPercentIsHighCandidateButNeedsConfirmation() {
    XCTAssertEqual(
        WindowServerPressureClassifier.classify(
            rollingCPU: 30.0,
            baselineCPU: 10.0,
            consecutiveHighCandidates: 1
        ),
        .elevated
    )
    XCTAssertEqual(
        WindowServerPressureClassifier.classify(
            rollingCPU: 30.0,
            baselineCPU: 10.0,
            consecutiveHighCandidates: 2
        ),
        .high
    )
}

func testRelativeHighCandidateRequiresTwentyPercentAndTwelvePointIncrease() {
    XCTAssertEqual(
        WindowServerPressureClassifier.classify(
            rollingCPU: 20.0,
            baselineCPU: 8.0,
            consecutiveHighCandidates: 2
        ),
        .high
    )
    XCTAssertEqual(
        WindowServerPressureClassifier.classify(
            rollingCPU: 19.9,
            baselineCPU: 7.0,
            consecutiveHighCandidates: 2
        ),
        .elevated
    )
}

func testMissingRollingCPUIsUnavailable() {
    XCTAssertEqual(
        WindowServerPressureClassifier.classify(
            rollingCPU: nil,
            baselineCPU: 10.0,
            consecutiveHighCandidates: 0
        ),
        .unavailable
    )
}
```

Also add a rolling-window test that records `10`, `20`, `30`, `40` and proves the current three-sample average is `30` after the fourth sample.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
cd app/CatalinaPerformance
swift test --filter WindowServerPressureModelsTests
```

Expected: compilation fails because the new WindowServer types do not exist.

- [ ] **Step 3: Implement the minimal typed model and classifier**

Use explicit constants:

```swift
public struct WindowServerPressureClassifier {
    public static let elevatedAbsoluteThreshold = 15.0
    public static let highAbsoluteThreshold = 30.0
    public static let elevatedDeltaThreshold = 8.0
    public static let highDeltaMinimumCPU = 20.0
    public static let highDeltaThreshold = 12.0
    public static let requiredHighCandidateCount = 2

    public static func isHighCandidate(
        rollingCPU: Double,
        baselineCPU: Double?
    ) -> Bool {
        if rollingCPU >= highAbsoluteThreshold {
            return true
        }
        guard let baselineCPU = baselineCPU else {
            return false
        }
        return rollingCPU >= highDeltaMinimumCPU &&
            rollingCPU - baselineCPU >= highDeltaThreshold
    }

    public static func classify(
        rollingCPU: Double?,
        baselineCPU: Double?,
        consecutiveHighCandidates: Int
    ) -> WindowServerPressureLevel {
        guard let rollingCPU = rollingCPU,
              rollingCPU.isFinite,
              rollingCPU >= 0 else {
            return .unavailable
        }

        if isHighCandidate(rollingCPU: rollingCPU, baselineCPU: baselineCPU),
           consecutiveHighCandidates >= requiredHighCandidateCount {
            return .high
        }

        if rollingCPU >= elevatedAbsoluteThreshold {
            return .elevated
        }

        if let baselineCPU = baselineCPU,
           baselineCPU.isFinite,
           rollingCPU - baselineCPU >= elevatedDeltaThreshold {
            return .elevated
        }

        return .normal
    }
}
```

`WindowServerSessionAggregate` must retain only the last three valid active CPU values for the rolling average, track sum/count/peak, count elapsed seconds by pressure level using sample timestamps, and ignore unavailable readings instead of inserting zero.

- [ ] **Step 4: Run the focused tests**

```bash
swift test --filter WindowServerPressureModelsTests
```

Expected: all WindowServer pressure-model tests pass.

- [ ] **Step 5: Commit**

```bash
git add \
  app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/WindowServerPressureModels.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/WindowServerPressureModelsTests.swift
git commit -m "feat: add WindowServer pressure models"
```

---

### Task 2: Add exact WindowServer discovery and cumulative CPU delta collection

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/WindowServerMetricsCollector.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/WindowServerMetricsCollectorTests.swift`

**Interfaces:**
- Consumes:
  - `AppPriorityProcessInspecting.allProcesses()`
  - `DashboardNativeMetricsProviding.processResources(pid:)`
- Produces:
  - `public protocol WindowServerMetricsCollecting: AnyObject { func capture(at date: Date) -> WindowServerCPUReading }`
  - `public final class WindowServerMetricsCollector: WindowServerMetricsCollecting`
  - `public func reset()`

- [ ] **Step 1: Write failing discovery and delta tests**

Use fake process identities and fake resource counters. Pin exact identity rules:

```swift
func testDiscoversOnlyExactWindowServerProcessName() {
    let inspector = FakeProcessInspector(processes: [
        process(pid: 101, name: "WindowServerHelper", path: "/tmp/WindowServerHelper", uid: 88),
        process(pid: 202, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", uid: 88)
    ])
    let native = FakeNativeMetrics(resources: [
        202: resource(pid: 202, startSeconds: 5, cpu: 1_000_000_000)
    ])
    let collector = WindowServerMetricsCollector(
        processInspector: inspector,
        nativeMetrics: native
    )

    let first = collector.capture(at: Date(timeIntervalSince1970: 10))
    XCTAssertNil(first.cpuPercent)
    XCTAssertEqual(first.processKey?.pid, 202)
}

func testSecondCounterReadingProducesNumericCPUPercentage() {
    let collector = makeCollector(cpuSequence: [1_000_000_000, 1_400_000_000])
    _ = collector.capture(at: Date(timeIntervalSince1970: 10))
    let second = collector.capture(at: Date(timeIntervalSince1970: 12))
    XCTAssertEqual(second.cpuPercent ?? -1, 20.0, accuracy: 0.001)
}
```

Add tests for:

- process name mismatch
- resource start-time mismatch
- negative/decreasing cumulative CPU time
- zero elapsed wall time
- PID replacement
- same PID with different start time
- temporary discovery failure followed by reacquisition
- multiple exact `WindowServer` candidates → unavailable rather than guessing

- [ ] **Step 2: Run focused tests and verify failure**

```bash
cd app/CatalinaPerformance
swift test --filter WindowServerMetricsCollectorTests
```

Expected: compilation failure because the collector does not exist.

- [ ] **Step 3: Implement exact discovery and delta calculation**

The implementation must:

```swift
private func exactCandidate(
    from processes: [AppPriorityProcessIdentity]
) -> AppPriorityProcessIdentity? {
    let matches = processes.filter { process in
        process.processName == "WindowServer" &&
            process.pid > 0 &&
            process.executablePath.hasSuffix("/WindowServer")
    }
    guard matches.count == 1 else { return nil }
    return matches[0]
}
```

After discovering a candidate, call `processResources(pid:)` and verify `pid`, `startSeconds`, and `startMicroseconds` against the process identity. Build `WindowServerProcessKey` from PID + start time + executable path.

CPU calculation:

```swift
let elapsed = date.timeIntervalSince(previous.capturedAt)
guard elapsed > 0,
      current.cpuTimeNanoseconds >= previous.cpuTimeNanoseconds else {
    previousCounter = currentCounter
    return .unavailable(
        processKey: key,
        at: date,
        note: "WindowServer CPU counter interval was invalid."
    )
}

let delta = current.cpuTimeNanoseconds - previous.cpuTimeNanoseconds
let percent = Double(delta) / (elapsed * 1_000_000_000.0) * 100.0
```

Do **not** clamp to 100%; a process can consume more than one logical CPU. Reject non-finite or negative percentages.

When identity changes, store the new counter but return Unavailable for that sample with a note indicating the process identity changed and a fresh baseline is required.

- [ ] **Step 4: Run focused tests**

```bash
swift test --filter WindowServerMetricsCollectorTests
```

Expected: all collector tests pass.

- [ ] **Step 5: Commit**

```bash
git add \
  app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/WindowServerMetricsCollector.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/WindowServerMetricsCollectorTests.swift
git commit -m "feat: collect WindowServer CPU pressure"
```

---

### Task 3: Carry WindowServer readings through session snapshots without breaking old JSON

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift`
- Modify: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionMetricModelsTests.swift`
- Modify: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionMetricsCollectorTests.swift`

**Interfaces:**
- Consumes: `WindowServerMetricsCollecting.capture(at:)`
- Produces:
  - `SessionMetricSnapshot.windowServerCPU: WindowServerCPUReading?`
  - `PerformanceSessionRecord.windowServer: WindowServerSessionAggregate?`
  - `CompletedPerformanceSessionReport.windowServer: WindowServerSessionAggregate?`

- [ ] **Step 1: Add failing Codable backward-compatibility tests**

Add a fixture-style test that decodes JSON produced by the current branch **without** any WindowServer keys:

```swift
func testOldVersionOneSnapshotDecodesWithoutWindowServerField() throws {
    let data = oldVersionOneSessionJSON()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(PerformanceSessionRecord.self, from: data)
    XCTAssertNil(record.windowServer)
    XCTAssertNil(record.baseline.windowServerCPU)
}
```

Add a round-trip test proving a new report with WindowServer aggregate encodes and decodes with the existing schema version `1`.

- [ ] **Step 2: Run the model tests and verify failure**

```bash
cd app/CatalinaPerformance
swift test --filter SessionMetricModelsTests
```

Expected: failure because the new optional fields are absent.

- [ ] **Step 3: Add optional additive fields**

In `SessionMetricSnapshot` add:

```swift
public let windowServerCPU: WindowServerCPUReading?
```

Use a custom `CodingKeys` + `init(from:)` only if synthesized decoding on the Catalina compiler does not preserve missing optional-field compatibility. If a custom decoder is needed, use explicit locals before assignment:

```swift
let windowServerCPU = try container.decodeIfPresent(
    WindowServerCPUReading.self,
    forKey: .windowServerCPU
)
```

and assign stored properties only after all decode operations complete.

Add optional `windowServer` fields to `PerformanceSessionRecord` and `CompletedPerformanceSessionReport`, with explicit public initializer arguments defaulting to `nil`.

- [ ] **Step 4: Inject WindowServer collector into `SessionMetricsCollector`**

Add:

```swift
private let windowServerCollector: WindowServerMetricsCollecting
```

and an initializer parameter. During `capture(at:refreshThermal:)`:

```swift
let windowServer = windowServerCollector.capture(at: date)
```

Return it as `windowServerCPU: windowServer`.

For test-only or non-Darwin callers, provide a simple injected fake; do not introduce a hidden global default that performs process scans unexpectedly.

- [ ] **Step 5: Run model and collector tests**

```bash
swift test --filter SessionMetricModelsTests
swift test --filter SessionMetricsCollectorTests
```

Expected: both suites pass, including old JSON decode and Unavailable propagation.

- [ ] **Step 6: Commit**

```bash
git add \
  app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionMetricModelsTests.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionMetricsCollectorTests.swift
git commit -m "feat: add WindowServer readings to dashboard snapshots"
```

---

### Task 4: Record graphics baseline, active aggregates, and restoration samples

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionRecorder.swift`
- Modify: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionRecorderTests.swift`

**Interfaces:**
- Produces additions to `PerformanceSessionRecording`:
  - `func beginGraphicsBaseline()`
  - `func recordGraphicsBaseline(sample: WindowServerCPUReading)`
  - `func finalizeGraphicsBaseline()`
- Existing `record(sample:)`, `markFinalizing(preRestore:at:)`, `complete(...)`, and `interrupt(...)` continue to update graphics metrics from `SessionMetricSnapshot.windowServerCPU`.

- [ ] **Step 1: Write failing recorder lifecycle tests**

Pin the required data flow:

```swift
func testThreeBaselineSamplesProduceBaselineAverageAndPeak() {
    let recorder = PerformanceSessionRecorder()
    recorder.begin(
        identifier: "session",
        startedAt: date(0),
        baseline: snapshot(windowServerCPU: nil),
        selectedApplication: nil
    )
    recorder.beginGraphicsBaseline()
    recorder.recordGraphicsBaseline(sample: ws(cpu: nil, at: 0))
    recorder.recordGraphicsBaseline(sample: ws(cpu: 10, at: 2))
    recorder.recordGraphicsBaseline(sample: ws(cpu: 20, at: 4))
    recorder.finalizeGraphicsBaseline()

    let graphics = recorder.activeRecord()?.windowServer
    XCTAssertEqual(graphics?.baselineSamples.count, 3)
    XCTAssertEqual(graphics?.baseline?.averageCPU ?? -1, 15, accuracy: 0.001)
    XCTAssertEqual(graphics?.baseline?.peakCPU ?? -1, 20, accuracy: 0.001)
}
```

The first baseline sample can legitimately have no CPU percentage because it establishes the cumulative counter baseline. The baseline summary averages only valid calculated CPU percentages while retaining all three raw samples.

Add tests that active samples update rolling/average/peak/time-in-state, and final/post samples land in the corresponding aggregate fields.

- [ ] **Step 2: Run recorder tests and verify failure**

```bash
cd app/CatalinaPerformance
swift test --filter PerformanceSessionRecorderTests
```

Expected: failure because graphics recording APIs do not exist.

- [ ] **Step 3: Implement graphics recording**

Keep graphics state optional until baseline collection starts. `record(sample:)` must update the graphics aggregate only when `sample.windowServerCPU` is non-nil. An Unavailable reading must still be retained as the latest reading but must not increase numeric average/count or time-in-pressure-state.

`markFinalizing` stores the final pre-restore WindowServer reading. `complete` stores the post-restore reading and includes the aggregate in the completed report.

- [ ] **Step 4: Run recorder tests**

```bash
swift test --filter PerformanceSessionRecorderTests
```

Expected: all recorder tests pass.

- [ ] **Step 5: Commit**

```bash
git add \
  app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionRecorder.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionRecorderTests.swift
git commit -m "feat: record WindowServer session aggregates"
```

---

### Task 5: Implement the scheduler-driven three-sample pre-ON graphics baseline

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift`
- Modify: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionCoordinatorTests.swift`

**Interfaces:**
- Modify `PerformanceSessionCoordinatorContent.preparing` to carry progress:

```swift
public struct PerformancePreparationProgress: Equatable {
    public let graphicsSampleIndex: Int
    public let graphicsSampleCount: Int
    public let message: String
}

case preparing(PerformancePreparationProgress)
```

- Keep `prepareForOn(selectedApplication:completion:)` as the external activation API.

- [ ] **Step 1: Add failing three-sample sequencing tests with a deterministic scheduler**

Use a fake scheduler that stores scheduled callbacks and allows tests to fire them manually. Do **not** use real `sleep` calls.

```swift
func testPrepareForOnCollectsExactlyThreeGraphicsSamplesBeforeCompletion() {
    let scheduler = ManualSessionScheduler()
    let collector = SequenceCollector([
        snapshot(ws: ws(cpu: nil, at: 0)),
        snapshot(ws: ws(cpu: 8, at: 2)),
        snapshot(ws: ws(cpu: 12, at: 4))
    ])
    var completed = false

    let coordinator = makeCoordinator(
        collector: collector,
        scheduler: scheduler
    )

    coordinator.prepareForOn(selectedApplication: nil) {
        completed = true
    }

    XCTAssertEqual(collector.captureCount, 1)
    XCTAssertFalse(completed)

    scheduler.fireNext()
    XCTAssertEqual(collector.captureCount, 2)
    XCTAssertFalse(completed)

    scheduler.fireNext()
    XCTAssertEqual(collector.captureCount, 3)
    XCTAssertTrue(completed)
}
```

Also capture coordinator states and assert progress `1/3`, `2/3`, `3/3` appears in order.

- [ ] **Step 2: Add failing non-blocking failure test**

All three WindowServer readings may be unavailable, but `prepareForOn` must still invoke completion after the third sample and preserve a warning/advisory instead of aborting activation.

- [ ] **Step 3: Run coordinator tests and verify failure**

```bash
cd app/CatalinaPerformance
swift test --filter PerformanceSessionCoordinatorTests
```

Expected: failures because preparation currently captures only one baseline snapshot.

- [ ] **Step 4: Implement the preparation sequence**

Do not repurpose the active repeating timer for baseline state in a way that can leak into the active session. Use scheduler-driven one-shot callbacks through a small private helper:

```swift
private func collectGraphicsBaselineSample(
    index: Int,
    selectedApplication: AppPriorityApplication?,
    completion: @escaping () -> Void
)
```

Required timing:

- sample 1 immediately
- sample 2 at approximately +2 seconds
- sample 3 at approximately +4 seconds
- then invoke the existing Performance Mode activation continuation

If the existing `PerformanceSessionScheduling` protocol cannot express one-shot delayed callbacks cleanly, extend it with:

```swift
func scheduleOnce(after interval: TimeInterval, _ action: @escaping () -> Void)
```

and implement it in `DispatchPerformanceSessionScheduler` on the same utility queue. Keep `scheduleRepeating` for active monitoring.

The coordinator must start the recorder session before sample 1 so the three raw graphics samples can be persisted if the app terminates during preparation.

- [ ] **Step 5: Run coordinator tests**

```bash
swift test --filter PerformanceSessionCoordinatorTests
```

Expected: exactly three pre-ON samples, deterministic progress, completion after sample 3, and non-blocking unavailable behavior all pass.

- [ ] **Step 6: Commit**

```bash
git add \
  app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionCoordinatorTests.swift
git commit -m "feat: measure graphics baseline before Performance Mode"
```

---

### Task 6: Add active and completed Graphics / WindowServer presentation models

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift`
- Modify: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionDashboardPresentationTests.swift`

**Interfaces:**
- Add to `SessionDashboardViewModel`:

```swift
public let graphicsRows: [SessionDashboardMetricRow]
public let graphicsAdvisoryText: String?
```

- Preparing status uses `PerformancePreparationProgress`.

- [ ] **Step 1: Write failing preparing-state tests**

Assert exact text:

```swift
XCTAssertEqual(
    viewModel.statusText,
    "Measuring graphics baseline… 2/3"
)
```

- [ ] **Step 2: Write failing active graphics-row tests**

For a valid active aggregate, expect labels:

```text
Pressure
Current CPU
Rolling Average
Session Average
Session Peak
Pre-ON Baseline
Change from Baseline
```

Use one-decimal percentages and percentage-point language for the delta. `Unavailable` must remain `Unavailable` rather than `0.0%`.

- [ ] **Step 3: Write failing completed-report tests**

Completed rows/advisory must expose:

- baseline average and peak
- active average and peak
- final pre-restore
- post-restore
- maximum sustained pressure
- time Normal / Elevated / High
- already-elevated-baseline advisory when applicable

Advisory copy must match the approved design and remain causal-neutral:

```text
WindowServer load was elevated during this session. No additional graphics changes were made automatically.
```

Never use wording such as `Visual Performance reduced WindowServer load by ...`.

- [ ] **Step 4: Run presenter tests and verify failure**

```bash
cd app/CatalinaPerformance
swift test --filter SessionDashboardPresentationTests
```

- [ ] **Step 5: Implement presentation helpers**

Add focused helpers rather than expanding `activeViewModel` into one large expression:

```swift
private func graphicsRows(_ aggregate: WindowServerSessionAggregate?) -> [SessionDashboardMetricRow]
private func graphicsAdvisory(_ aggregate: WindowServerSessionAggregate?) -> String?
private func pressureText(_ level: WindowServerPressureLevel) -> String
private func secondsText(_ seconds: TimeInterval) -> String
```

`graphicsRows(nil)` returns a short Unavailable state rather than fabricating metrics.

- [ ] **Step 6: Run presenter tests**

```bash
swift test --filter SessionDashboardPresentationTests
```

Expected: preparing, active, completed, unavailable, and already-elevated cases pass.

- [ ] **Step 7: Commit**

```bash
git add \
  app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionDashboardPresentationTests.swift
git commit -m "feat: present WindowServer pressure in dashboard models"
```

---

### Task 7: Render a dedicated Graphics / WindowServer AppKit section

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift`
- Modify: `scripts/tests/test_session_dashboard_ui_source.sh`

**Interfaces:**
- Consumes `SessionDashboardViewModel.graphicsRows` and `.graphicsAdvisoryText`.
- Produces no new system behavior.

- [ ] **Step 1: Add failing source-contract assertions**

Extend `test_session_dashboard_ui_source.sh` to require the exact heading:

```sh
grep -F 'section(title: "Graphics / WindowServer"' "$SOURCE" >/dev/null || fail 'missing Graphics / WindowServer dashboard section'
```

Also reject accidental mutation/process-control additions in the WindowServer dashboard path:

```sh
if grep -R -nE 'killall[[:space:]]+WindowServer|pkill.*WindowServer|renice.*WindowServer|defaults[[:space:]]+write.*WindowServer' \
  app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore \
  app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift; then
    fail 'WindowServer telemetry contains a prohibited mutation path'
fi
```

- [ ] **Step 2: Run source-contract test and verify failure**

```bash
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
```

Expected: failure because the dedicated section is not rendered.

- [ ] **Step 3: Add the dedicated section**

In `rebuildContent(from:)`, after the System section and before Selected App:

```swift
if !viewModel.graphicsRows.isEmpty {
    addFullWidthArrangedSubview(
        section(
            title: "Graphics / WindowServer",
            metricRows: viewModel.graphicsRows
        )
    )
}
```

If `graphicsAdvisoryText` exists, render it directly below that section as a wrapping secondary label with an accessibility label/value. Do not place it in the warning banner because Elevated/High telemetry is advisory, not a restoration failure.

- [ ] **Step 4: Run source-contract test**

```bash
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add \
  app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift \
  scripts/tests/test_session_dashboard_ui_source.sh
git commit -m "feat: show WindowServer pressure dashboard section"
```

---

### Task 8: Wire the real WindowServer collector into production without adding another timer

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Modify: `app/CatalinaPerformance/Package.swift` only if an existing target dependency is insufficient
- Modify: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionMetricsCollectorTests.swift`

**Interfaces:**
- Consumes `DarwinAppPriorityProcessInspector` and `DarwinDashboardNativeMetrics` already used by dashboard/app-priority infrastructure.

- [ ] **Step 1: Add/adjust construction test coverage**

Keep unit tests dependency-injected. Add a collector-integration test proving a fake WindowServer collector is called exactly once per `SessionMetricsCollector.capture(...)` invocation.

- [ ] **Step 2: Run collector tests**

```bash
cd app/CatalinaPerformance
swift test --filter SessionMetricsCollectorTests
```

Expected before production wiring: test passes only after test constructor is updated; application build may still fail until production construction is updated.

- [ ] **Step 3: Wire production instances in `makePerformanceSessionCoordinator()`**

Construct one shared native metrics provider and one process inspector for the collector tree:

```swift
let nativeMetrics = DarwinDashboardNativeMetrics()
let processInspector = DarwinAppPriorityProcessInspector()
let windowServerCollector = WindowServerMetricsCollector(
    processInspector: processInspector,
    nativeMetrics: nativeMetrics
)

let collector = SessionMetricsCollector(
    nativeMetrics: nativeMetrics,
    thermalProvider: thermalProvider,
    diskSpaceProvider: StartupVolumeDiskSpaceProvider(),
    selectionProvider: UserDefaultsAppPrioritySelectionProvider(),
    statusProvider: JSONAppPriorityStatusProvider(statusURL: priorityStatusURL),
    currentUserProvider: ProcessDashboardCurrentUserProvider(),
    processInspector: processInspector,
    windowServerCollector: windowServerCollector
)
```

Do not instantiate a DispatchSourceTimer or background service for WindowServer here. The coordinator remains the sole scheduler owner.

- [ ] **Step 4: Build both products**

```bash
cd app/CatalinaPerformance
swift build --product CatalinaPerformance
swift build --product CatalinaPerformancePriorityAgent
```

Expected: both builds complete.

- [ ] **Step 5: Commit**

```bash
git add \
  app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift \
  app/CatalinaPerformance/Package.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/SessionMetricsCollectorTests.swift
git commit -m "feat: wire WindowServer telemetry into session monitoring"
```

Do not stage `Package.swift` if no dependency change was necessary.

---

### Task 9: Verify persistence, interruption recovery, and report-size behavior

**Files:**
- Modify: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionStoreTests.swift`
- Modify: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionRecorderTests.swift`

**Interfaces:**
- Existing `PerformanceSessionStore` remains unchanged unless a real test exposes a compatibility issue.

- [ ] **Step 1: Add completed-report persistence test with graphics metrics**

Persist a report containing three baseline samples, several active readings, and final/post readings. Reload it and assert exact equality.

- [ ] **Step 2: Add old-report decode test through the store**

Write a valid schema-1 JSON fixture without graphics fields to `last-completed-session.json`; assert `loadCompleted()` returns `.loaded` and `report.windowServer == nil` rather than moving it to an invalid backup.

- [ ] **Step 3: Add interrupted-session preservation test**

Interrupt a record after baseline/active graphics readings and assert the completed interrupted report retains the graphics aggregate and final pre-restore reading.

- [ ] **Step 4: Run store and recorder tests**

```bash
cd app/CatalinaPerformance
swift test --filter PerformanceSessionStoreTests
swift test --filter PerformanceSessionRecorderTests
```

Expected: pass without increasing `PerformanceSessionStore.maximumFileSize` unless an actual encoded report demonstrably exceeds the existing 1 MiB bound. Do not preemptively raise the safety limit.

- [ ] **Step 5: Commit**

```bash
git add \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionStoreTests.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/PerformanceSessionRecorderTests.swift
git commit -m "test: cover WindowServer dashboard persistence"
```

---

### Task 10: Add Catalina runtime checklist and regression documentation

**Files:**
- Modify: `docs/GUI_TESTING.md`
- Modify: `docs/TESTING_CHECKLIST.md`

**Interfaces:** none.

- [ ] **Step 1: Add exact Catalina runtime procedure**

Document this sequence:

```text
1. Launch the packaged CatalinaPerformance.app normally.
2. Open Session Dashboard before starting a session and confirm no crash.
3. Turn Performance Mode ON.
4. Confirm the UI shows "Measuring graphics baseline… 1/3", then 2/3, then 3/3 over roughly four seconds.
5. Confirm Performance Mode proceeds even if the Graphics / WindowServer section is Unavailable.
6. While ON, keep Session Dashboard open and confirm Current CPU updates on the existing two-second cadence.
7. Exercise normal window opening and Mission Control; verify one transient spike does not immediately produce sustained High.
8. Run a graphics-heavier workload long enough to observe Elevated/High if the machine naturally reaches those levels; do not force system instability.
9. Turn Performance Mode OFF.
10. Confirm the completed report contains baseline average/peak, active average/peak, final pre-restore, post-restore, maximum pressure, and time-in-state values.
11. Confirm Visual Performance restoration still reports independently and correctly.
12. Confirm OFF and Emergency Restore remain usable when WindowServer telemetry is unavailable.
```

- [ ] **Step 2: Add explicit safety assertions**

Document that runtime verification must confirm:

- no authorization prompt is caused by WindowServer monitoring
- WindowServer PID changes do not crash the app
- Unavailable is displayed instead of zero
- no WindowServer/Finder/Dock restart occurs
- no desktop/wallpaper/display setting changes occur

- [ ] **Step 3: Commit**

```bash
git add docs/GUI_TESTING.md docs/TESTING_CHECKLIST.md
git commit -m "docs: add WindowServer pressure runtime checks"
```

---

### Task 11: Run full automated regression and source-safety verification

**Files:**
- Modify only if a real regression is found.

**Interfaces:** none.

- [ ] **Step 1: Run dashboard-focused tests**

```bash
cd app/CatalinaPerformance
swift test --filter WindowServerPressureModelsTests
swift test --filter WindowServerMetricsCollectorTests
swift test --filter SessionMetricModelsTests
swift test --filter SessionMetricsCollectorTests
swift test --filter PerformanceSessionRecorderTests
swift test --filter PerformanceSessionCoordinatorTests
swift test --filter SessionDashboardPresentationTests
swift test --filter PerformanceSessionStoreTests
```

Expected: all pass.

- [ ] **Step 2: Run the complete Swift suite**

```bash
swift test
```

Expected: all tests pass; platform-specific macOS tests may be skipped only where the existing suite already intentionally skips them on non-macOS hosts.

- [ ] **Step 3: Build both products**

```bash
swift build --product CatalinaPerformance
swift build --product CatalinaPerformancePriorityAgent
cd ../..
```

Expected: both builds complete.

- [ ] **Step 4: Run all existing source/shell regressions**

```bash
/bin/sh scripts/tests/test_foreground_session.sh all
/bin/sh scripts/tests/test_advanced_layout_source.sh
/bin/sh scripts/tests/test_app_priority_wrappers.sh
/bin/sh scripts/tests/test_app_priority_ui_source.sh
/bin/sh scripts/tests/test_catalina_process_support_source.sh
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
/bin/sh scripts/tests/test_background_service_ui_source.sh
/bin/sh scripts/tests/test_visual_performance_production_source.sh
/bin/sh scripts/tests/test_visual_performance_operation_boundary.sh
```

Expected: all pass.

- [ ] **Step 5: Run syntax, prohibited-operation, and whitespace checks**

```bash
find scripts -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do
    /bin/sh -n "$file" || exit 1
done

grep -RInE \
  'killall[[:space:]]+WindowServer|pkill.*WindowServer|renice.*WindowServer|defaults[[:space:]]+write.*WindowServer' \
  app/CatalinaPerformance/Sources || true

git diff --check
```

Expected:

- shell syntax loop exits 0
- prohibited-operation grep prints nothing
- `git diff --check` prints nothing

- [ ] **Step 6: Review the complete diff**

```bash
git status --short
git diff --stat agent/windowserver-pressure-design^..HEAD
git diff --check
```

Confirm the patch does not contain unrelated graphics preference mutations, desktop-icon/wallpaper controls, new daemons, or new privileged execution paths.

- [ ] **Step 7: Commit any test-only cleanup if needed**

Only if verification required legitimate source/test corrections:

```bash
git add <exact corrected files>
git commit -m "test: finalize WindowServer pressure monitoring"
```

Do not create an empty cleanup commit.

---

### Task 12: Package and perform hands-on Catalina validation

**Files:**
- No source changes unless runtime evidence exposes a real bug.

**Interfaces:** none.

- [ ] **Step 1: Package from the verified tree**

```bash
cd ~/Desktop/CatalinaPerformance
pkill -x CatalinaPerformance 2>/dev/null || true
rm -rf build
./scripts/package_app.sh
```

Expected: packaged application created successfully.

- [ ] **Step 2: Launch and validate the pre-ON sequence**

```bash
open ./build/CatalinaPerformance.app
```

Confirm the visible preparation sequence progresses through `1/3`, `2/3`, `3/3` before Performance Mode applies its existing changes.

- [ ] **Step 3: Validate live telemetry**

Open Session Dashboard while Performance Mode is active and confirm:

```text
Graphics / WindowServer
Pressure: <Normal|Elevated|High|Unavailable>
Current CPU: <value or Unavailable>
Rolling Average: <value or Unavailable>
Session Average: <value or Unavailable>
Session Peak: <value or Unavailable>
Pre-ON Baseline: <value or Unavailable>
Change from Baseline: <value or Unavailable>
```

Readings should update about every two seconds with no new authorization prompt.

- [ ] **Step 4: Validate transient spike handling**

Open/close windows and use Mission Control briefly. A single spike must not immediately produce sustained High; High requires two consecutive High-candidate rolling classifications.

- [ ] **Step 5: Validate OFF and completed report**

Turn Performance Mode OFF and confirm restoration succeeds. Reopen/refresh Session Dashboard and verify baseline, active, final pre-restore, post-restore, maximum pressure, time-in-state, and advisory data remain visible.

- [ ] **Step 6: Validate failure isolation**

If WindowServer telemetry naturally becomes Unavailable or can be safely made unavailable without killing/restarting WindowServer, confirm Performance Mode OFF and Emergency Restore remain fully usable. Do **not** terminate WindowServer to manufacture this test.

- [ ] **Step 7: Only after Catalina runtime validation, commit runtime-only corrections if necessary**

Any runtime bug must first be reproduced and root-caused. Apply the smallest correction with a regression test, rerun the relevant focused suite, rerun the full automated verification, then repeat the affected Catalina validation step.

---

## Self-Review Results

### Spec coverage

- Three-sample ~4-second baseline: Task 5.
- Existing two-second active cadence: Tasks 5 and 8.
- Exact WindowServer discovery and identity verification: Task 2.
- Cumulative CPU-time delta calculation: Task 2.
- PID replacement/reacquisition: Task 2.
- Normal/Elevated/High/Unavailable hybrid rules: Task 1.
- Three-sample rolling average: Task 1.
- Two-consecutive-High requirement: Task 1.
- Already-elevated baseline handling: Tasks 1 and 6.
- Raw baseline, active average/peak, final, post, time-in-state persistence: Tasks 4 and 9.
- Dedicated dashboard section and neutral advisories: Tasks 6 and 7.
- Monitoring failure never blocks lifecycle: Tasks 5 and 12.
- No additional timer/daemon/helper/mutation: Tasks 7, 8, and 11.
- Backward-compatible existing dashboard JSON: Tasks 3 and 9.
- Catalina runtime verification: Tasks 10 and 12.

### Placeholder scan

No `TBD`, `TODO`, `implement later`, `similar to`, or unspecified error-handling steps remain. Each implementation task names concrete files, interfaces, test commands, expected failures/passes, and commit boundaries.

### Type consistency

The plan consistently uses:

- `WindowServerPressureLevel`
- `WindowServerProcessKey`
- `WindowServerCPUReading`
- `WindowServerBaselineSummary`
- `WindowServerSessionAggregate`
- `WindowServerMetricsCollecting`
- `WindowServerMetricsCollector`
- `PerformancePreparationProgress`
- `SessionDashboardViewModel.graphicsRows`
- `SessionDashboardViewModel.graphicsAdvisoryText`

No alternate names are used for these interfaces in later tasks.
