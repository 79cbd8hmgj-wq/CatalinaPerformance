# Memory Pressure & Swap Management 1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Catalina-specific memory-pressure manager that detects sustained VM contention, ranks verified noncritical background application families, temporarily applies nice `+5` and only calibrated reversible I/O/background policy to at most three families, and restores their exact original state automatically.

**Architecture:** Add a new `CatalinaPerformanceMemoryCore` target for telemetry models, classification, family analysis, persistence, and intervention policy. Extend `CatalinaProcessSupport` with read-only Catalina VM counters, feed those counters through the existing 2-second Performance Session collector, and keep all mutations behind verified process identity plus persisted recovery state. Reuse the existing App Priority process identity/mutator boundary and main AppKit lifecycle; do not add another high-frequency VM timer, permanent daemon, VM/kernel tuning, application killing, swap disabling, or `purge` behavior.

**Tech Stack:** Swift 5.2 / macOS Catalina 10.15.7 / AppKit / Foundation / SwiftPM / C Darwin APIs (`host_statistics64`, `sysctl`, `libproc`) / existing shell test harness.

## Global Constraints

- macOS minimum remains Catalina 10.15; code must compile with Xcode 12.4-era Swift.
- Reuse the existing 2-second Performance Session sampling cadence; do not add another high-frequency VM telemetry timer.
- A single abnormal sample must never authorize mutation.
- High requires 3 consecutive High candidates; Critical requires 2 consecutive Critical candidates; restoration after pressure recovery requires 5 consecutive Healthy samples.
- A family must remain background for 3 consecutive samples before becoming eligible.
- A family must contribute at least `max(256 MB, 5% of physical RAM)` to qualify.
- Manage at most 3 qualifying process families at once.
- CPU deprioritization target is nice `+5`; never raise a process above its pre-intervention scheduling priority.
- `taskpolicy` is optional and remains Unsupported until Catalina calibration proves capture, apply, verify, restore, and verify-restored behavior on a disposable process.
- Never mutate foreground apps, the configured App Priority target, CatalinaPerformance, WindowServer, Finder, Dock, SystemUIServer, loginwindow, launchd, kernel_task, root-owned processes, AirDrop/network/Bluetooth/audio/security infrastructure, or any process whose PID/UID/path/start-time identity cannot be reverified.
- Unavailable telemetry is never converted to zero.
- Persistence must succeed before mutation.
- PID reuse or identity mismatch means do not touch.
- No app termination, swap disabling, swap-file deletion, `purge`, undocumented VM/kernel tuning, arbitrary daemon unloading, SMC writes, MSR writes, kexts, or SIP changes.
- Preserve AirDrop and existing Background Service Suppression user-resume decisions.
- Performance Mode OFF and Emergency Restore override hysteresis and begin restoration immediately.

---

## File Structure

### New production files

- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryModels.swift` — raw VM readings, derived rates, pressure evidence, and public snapshot models.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryPressureClassifier.swift` — deterministic multi-signal candidate scoring plus sustained-state/hysteresis state machine.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryProcessFamilyAnalyzer.swift` — verified same-user family construction, protection policy, background-stability tracking, significance filter, and deterministic ranking.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementStateStore.swift` — versioned atomic recovery-state persistence with corrupt-state backup and unresolved-restoration retention.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryInterventionController.swift` — exact nice capture/apply/verify/restore behavior and optional calibrated I/O policy adapter.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementCoordinator.swift` — consumes each 2-second sample, drives classifier/family analysis/intervention, handles foreground/App Priority conflicts, and exposes dashboard status.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift` — reviewed static Catalina capability/profile constants populated only after probe evidence.
- `scripts/memory_vm_probe.sh` — read-only Catalina VM capability probe.
- `scripts/memory_taskpolicy_calibration.sh` — explicit disposable-process taskpolicy calibration; no production policy is enabled by this script itself.
- `scripts/tests/test_memory_vm_probe_source.sh` — source-safety contract for the VM probe.
- `scripts/tests/test_memory_taskpolicy_calibration_source.sh` — source-safety contract for taskpolicy calibration.

### New tests

- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryPressureClassifierTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryProcessFamilyAnalyzerTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementStateStoreTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementCoordinatorTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionMetricIntegrationTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionDashboardPresentationTests.swift`

### Existing files to modify

- `app/CatalinaPerformance/Package.swift`
- `app/CatalinaPerformance/Sources/CatalinaProcessSupport/include/CatalinaProcessSupport.h`
- `app/CatalinaPerformance/Sources/CatalinaProcessSupport/CatalinaProcessSupport.c`
- `app/CatalinaPerformance/Sources/CatalinaPerformancePriorityCore/AppPriorityProcessInspector.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/ProductionSessionMetricsCollector.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionRecorder.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- `scripts/package_app.sh`
- `scripts/tests/test_session_dashboard_ui_source.sh`
- `docs/TESTING_CHECKLIST.md`

---

### Task 1: Add the Memory Core target and stable public models

**Files:**
- Modify: `app/CatalinaPerformance/Package.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryModels.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift`

**Interfaces:**
- Produces: `MemoryPressureState`, `MemoryVMCounters`, `MemoryTelemetrySnapshot`, `MemoryTelemetryRates`, `MemoryManagedProcessRecord`, `MemoryManagedFamilyRecord`, `MemoryManagementStatusSnapshot`.
- Later tasks consume these exact types.

- [ ] **Step 1: Write failing model tests**

```swift
func testMemoryPressureStateOrdersBySeverity() {
    XCTAssertLessThan(MemoryPressureState.healthy, .elevated)
    XCTAssertLessThan(MemoryPressureState.elevated, .high)
    XCTAssertLessThan(MemoryPressureState.high, .critical)
}

func testUnavailableRatesRemainNil() {
    let rates = MemoryTelemetryRates(
        compressionBytesPerSecond: nil,
        swapGrowthBytesPerSecond: nil,
        swapInBytesPerSecond: nil,
        swapOutBytesPerSecond: nil,
        pageOutsPerSecond: nil
    )
    XCTAssertNil(rates.swapOutBytesPerSecond)
}
```

- [ ] **Step 2: Run the new test target and confirm failure**

Run:

```bash
cd app/CatalinaPerformance
swift test --filter MemoryTelemetryModelsTests
```

Expected: FAIL because the memory target/types do not exist.

- [ ] **Step 3: Add the target and minimal public models**

Add to `Package.swift`:

```swift
.target(
    name: "CatalinaPerformanceMemoryCore",
    dependencies: ["CatalinaPerformancePriorityCore", "CatalinaProcessSupport"]
),
.testTarget(
    name: "CatalinaPerformanceMemoryTests",
    dependencies: ["CatalinaPerformanceMemoryCore", "CatalinaPerformancePriorityCore", "CatalinaProcessSupport"]
),
```

Add `CatalinaPerformanceMemoryCore` to both the main executable and dashboard-core dependencies.

Define:

```swift
public enum MemoryPressureState: Int, Codable, Comparable {
    case healthy = 0, elevated = 1, high = 2, critical = 3
    public static func < (lhs: MemoryPressureState, rhs: MemoryPressureState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct MemoryVMCounters: Codable, Equatable {
    public let physicalBytes: UInt64
    public let availableBytes: UInt64
    public let compressedBytes: UInt64?
    public let swapUsedBytes: UInt64
    public let compressions: UInt64?
    public let decompressions: UInt64?
    public let pageIns: UInt64?
    public let pageOuts: UInt64?
    public let swapIns: UInt64?
    public let swapOuts: UInt64?
}
```

Use explicit public initializers for every public model.

- [ ] **Step 4: Run model tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/CatalinaPerformance/Package.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift
git commit -m "feat: add memory management core models"
```

---

### Task 2: Extend Catalina native VM telemetry without changing system state

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaProcessSupport/include/CatalinaProcessSupport.h`
- Modify: `app/CatalinaPerformance/Sources/CatalinaProcessSupport/CatalinaProcessSupport.c`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryCollector.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift`

**Interfaces:**
- Produces: `MemoryTelemetryCollecting.capture(at:) -> MemoryTelemetrySnapshot`.
- C boundary produces `CPVMMemoryInfo` through `cp_read_vm_memory_info`.

- [ ] **Step 1: Add a failing collector test with a fake native provider**

```swift
func testCollectorComputesRatesFromMonotonicCounters() {
    let previous = MemoryVMCounters(/* swapOuts: 100, compressions: 1000 */)
    let current = MemoryVMCounters(/* swapOuts: 140, compressions: 1100 */)
    let rates = MemoryRateCalculator.rates(previous: previous, current: current, elapsed: 2.0, pageSize: 4096)
    XCTAssertEqual(rates.swapOutBytesPerSecond, 81_920)
    XCTAssertEqual(rates.compressionBytesPerSecond, 204_800)
}
```

Also test counter decrease => nil rate, not zero.

- [ ] **Step 2: Add the C struct and read-only API**

In the header:

```c
typedef struct {
    uint64_t physicalBytes;
    uint64_t freePages;
    uint64_t inactivePages;
    uint64_t activePages;
    uint64_t wiredPages;
    uint64_t speculativePages;
    uint64_t purgeablePages;
    uint64_t compressorPages;
    uint64_t pagesStoredInCompressor;
    uint64_t compressions;
    uint64_t decompressions;
    uint64_t pageIns;
    uint64_t pageOuts;
    uint64_t swapIns;
    uint64_t swapOuts;
    uint64_t pageSize;
} CPVMMemoryInfo;

int32_t cp_read_vm_memory_info(CPVMMemoryInfo *output);
```

On Apple, populate only fields proven present in Catalina's `vm_statistics64_data_t`; leave unsupported values behind an explicit availability mask or sentinel rather than inventing zero semantics. On non-Apple builds return `-ENOTSUP`.

- [ ] **Step 3: Implement `DarwinMemoryTelemetryCollector`**

```swift
public protocol MemoryTelemetryCollecting {
    func capture(at date: Date) -> MemoryTelemetrySnapshot
}

public final class DarwinMemoryTelemetryCollector: MemoryTelemetryCollecting {
    private var previous: (date: Date, counters: MemoryVMCounters)?
    public func capture(at date: Date) -> MemoryTelemetrySnapshot { /* read + derive */ }
}
```

Use `{ Double($0) }` for `UInt64` numeric conversion; never `value.map(Double.init)`.

- [ ] **Step 4: Run focused tests and existing process-support tests**

```bash
swift test --filter MemoryTelemetryModelsTests
swift test --filter ProcessSupportSmokeTests
```

Expected: PASS on supported platforms; macOS-only smoke branches are validated later on Catalina.

- [ ] **Step 5: Commit**

```bash
git add app/CatalinaPerformance/Sources/CatalinaProcessSupport \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryCollector.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift
git commit -m "feat: collect Catalina VM telemetry"
```

---

### Task 3: Build the read-only Catalina VM capability probe and stop at the evidence gate

**Files:**
- Create: `scripts/memory_vm_probe.sh`
- Create: `scripts/tests/test_memory_vm_probe_source.sh`
- Modify: `docs/TESTING_CHECKLIST.md`

**Interfaces:**
- Produces an evidence file only; no production constants are approved in this task.

- [ ] **Step 1: Write the source contract first**

The source test must require absolute read-only commands and reject mutation strings:

```sh
grep -F '/usr/bin/vm_stat' scripts/memory_vm_probe.sh
grep -F '/usr/bin/memory_pressure' scripts/memory_vm_probe.sh
grep -F 'vm.swapusage' scripts/memory_vm_probe.sh
! grep -Eq '(^|[[:space:]])(purge|killall|launchctl[[:space:]]+(bootout|unload)|sysctl[[:space:]]+-w|rm[[:space:]].*swap)' scripts/memory_vm_probe.sh
```

- [ ] **Step 2: Run the source test and confirm failure before the probe exists**

```bash
/bin/sh scripts/tests/test_memory_vm_probe_source.sh
```

- [ ] **Step 3: Implement the probe**

The probe records:

```text
sw_vers
uname -a
sysctl hw.memsize
sysctl vm.swapusage
vm_stat
memory_pressure
selected read-only sysctl vm.* values
three successive vm_stat captures separated by 2 seconds
```

It must never use sudo or write a preference/sysctl.

- [ ] **Step 4: Run the source contract**

Expected: `PASS: Memory VM probe source contract`.

- [ ] **Step 5: Commit the checkpoint**

```bash
git add scripts/memory_vm_probe.sh scripts/tests/test_memory_vm_probe_source.sh docs/TESTING_CHECKLIST.md
git commit -m "test: add Catalina VM capability probe"
```

- [ ] **Step 6: HARD STOP — collect Catalina evidence before Task 4**

Run on the target Mac:

```bash
/bin/sh scripts/memory_vm_probe.sh \
  --output "$HOME/Desktop/catalina-10.15.7-memory-vm-probe.txt"
```

Do not implement mutation thresholds until the evidence confirms units, monotonic counters, and supported fields.

---

### Task 4: Freeze reviewed Catalina capabilities and static pressure constants

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/CatalinaMemoryCapabilitiesTests.swift`
- Modify: `docs/TESTING_CHECKLIST.md`

**Interfaces:**
- Produces: `CatalinaMemoryCapabilities.current` and `MemoryPressureThresholds.catalina10157`.

- [ ] **Step 1: Translate only verified probe evidence into capability flags**

```swift
public struct CatalinaMemoryCapabilities: Equatable {
    public let compressedBytes: Bool
    public let compressionCounters: Bool
    public let pageOutCounters: Bool
    public let swapInOutCounters: Bool
    public let nativePressureState: Bool
    public let taskPolicy: Bool
}
```

- [ ] **Step 2: Write threshold tests before constants**

Tests must assert the already-approved percentage thresholds exactly:

```swift
XCTAssertEqual(profile.availableModerateFraction, 0.15)
XCTAssertEqual(profile.availableStrongFraction, 0.08)
XCTAssertEqual(profile.availableSevereFraction, 0.05)
XCTAssertEqual(profile.compressedModerateFraction, 0.20)
XCTAssertEqual(profile.compressedStrongFraction, 0.30)
```

Rate thresholds must use the conservative values justified by the probe; include the actual numeric constants and evidence comment in this file during execution.

- [ ] **Step 3: Implement the static profile and run tests**

```bash
swift test --filter CatalinaMemoryCapabilitiesTests
```

- [ ] **Step 4: Commit**

```bash
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/CatalinaMemoryCapabilitiesTests.swift \
  docs/TESTING_CHECKLIST.md
git commit -m "feat: calibrate Catalina memory pressure profile"
```

---

### Task 5: Implement the multi-signal pressure classifier and recovery hysteresis

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryPressureClassifier.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryPressureClassifierTests.swift`

**Interfaces:**
- Consumes: `MemoryTelemetrySnapshot`, `MemoryPressureThresholds`.
- Produces: `MemoryPressureEvaluation` with `candidateState`, `confirmedState`, `healthyRecoveryCount`, and evidence strings.

- [ ] **Step 1: Write failing state-machine tests**

Cover exactly:

```swift
func testSingleHighCandidateDoesNotIntervene()
func testThreeHighCandidatesConfirmHigh()
func testTwoCriticalCandidatesConfirmCritical()
func testThreeElevatedCandidatesConfirmElevated()
func testFiveHealthySamplesAfterInterventionRequestRestore()
func testElevatedSampleResetsHealthyRecoveryCounter()
func testStableHistoricalSwapDoesNotCreatePressureEvidence()
func testUnavailableMetricContributesNoEvidence()
```

- [ ] **Step 2: Implement deterministic evidence scoring**

Use explicit named evidence points, not opaque weights. Example shape:

```swift
public struct MemoryPressureEvidence: OptionSet, Codable {
    public let rawValue: UInt32
    public static let lowAvailable = MemoryPressureEvidence(rawValue: 1 << 0)
    public static let severeAvailable = MemoryPressureEvidence(rawValue: 1 << 1)
    public static let compressionHigh = MemoryPressureEvidence(rawValue: 1 << 2)
    public static let compressionGrowing = MemoryPressureEvidence(rawValue: 1 << 3)
    public static let swapGrowing = MemoryPressureEvidence(rawValue: 1 << 4)
    public static let swapOutActive = MemoryPressureEvidence(rawValue: 1 << 5)
    public static let swapChurn = MemoryPressureEvidence(rawValue: 1 << 6)
}
```

- [ ] **Step 3: Implement confirmation counters exactly as specified**

No intervention flag may become true before 3 High or 2 Critical consecutive candidates.

- [ ] **Step 4: Run tests**

```bash
swift test --filter MemoryPressureClassifierTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryPressureClassifier.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryPressureClassifierTests.swift
git commit -m "feat: classify sustained memory pressure"
```

---

### Task 6: Add resident-memory process inspection and verified family ranking

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformancePriorityCore/AppPriorityProcessInspector.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryProcessFamilyAnalyzer.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryProcessFamilyAnalyzerTests.swift`

**Interfaces:**
- Add `AppPriorityProcessResourceInspecting.residentBytes(pid:)` to PriorityCore without changing existing CPU-activity semantics.
- Produces: `MemoryProcessFamilyCandidate` and `MemoryProcessFamilyAnalyzer.evaluate(...)`.

- [ ] **Step 1: Add a focused resource-inspection protocol**

```swift
public protocol AppPriorityProcessResourceInspecting {
    func residentBytes(pid: Int32) throws -> UInt64
}
```

Make `DarwinAppPriorityProcessInspector` conform using `cp_read_process_resources`.

- [ ] **Step 2: Write family-analyzer tests before implementation**

Tests must cover:

```text
same-user family grouping
3-sample background eligibility
frontmost family exclusion
App Priority target exclusion
root-owned exclusion
protected exact-path exclusion
minimum max(256 MB, 5% RAM) threshold
memory-growth tie-break
stable deterministic ordering
maximum three selected families
recently foregrounded penalty
```

- [ ] **Step 3: Implement explicit protection policy**

Create static exact-name/path protections for the already-approved critical processes and a Catalina protected-infrastructure path table. Candidate admission must default to denied when frontmost identity is unavailable.

- [ ] **Step 4: Implement deterministic ranking**

Sort by a documented tuple, for example:

```swift
(-memoryTier, -growthTier, -backgroundSampleCount, canonicalFamilyIdentifier)
```

Do not use randomized or floating opaque scoring.

- [ ] **Step 5: Run tests and commit**

```bash
swift test --filter MemoryProcessFamilyAnalyzerTests
git add app/CatalinaPerformance/Sources/CatalinaPerformancePriorityCore/AppPriorityProcessInspector.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryProcessFamilyAnalyzer.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryProcessFamilyAnalyzerTests.swift
git commit -m "feat: rank safe background memory families"
```

---

### Task 7: Add atomic recovery-state persistence before any mutation

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementStateStore.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementStateStoreTests.swift`

**Interfaces:**
- Produces: `MemoryManagementStateStoring` with `loadActive`, `saveActive`, `complete`, `removeActiveIfResolved`.
- State directory: `~/Library/Application Support/CatalinaPerformance/memory_management/`.

- [ ] **Step 1: Write persistence tests**

Cover:

```text
0600 file permissions
0700 directory permissions
atomic temp+fsync+rename write
symlink rejection
1 MB size limit
schema mismatch
corrupt active-state backup
unresolved restoration prevents active-state deletion
resolved record clears active state
```

- [ ] **Step 2: Implement versioned records**

```swift
public struct MemoryManagementSessionRecord: Codable, Equatable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let sessionIdentifier: String
    public let requestingUID: UInt32
    public let startedAt: Date
    public var managedFamilies: [MemoryManagedFamilyRecord]
    public var hasOutstandingRestoration: Bool { /* unresolved process records */ }
}
```

- [ ] **Step 3: Reuse the BackgroundServiceStateStore safety pattern**

Do not share its file; duplicate the narrow atomic mechanics into this subsystem so schema/lifecycle remain isolated.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter MemoryManagementStateStoreTests
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementStateStore.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementStateStoreTests.swift
git commit -m "feat: persist memory intervention recovery state"
```

---

### Task 8: Implement exact nice `+5` intervention and restore-first replacement

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryInterventionController.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift`

**Interfaces:**
- Consumes: `AppPriorityProcessInspecting`, `AppPriorityPriorityMutating`, `MemoryManagementStateStoring`.
- Produces: `apply(families:)`, `restore(familyID:)`, `restoreAll()`, `recoverStaleState()`.

- [ ] **Step 1: Write mutation tests first**

Required cases:

```swift
original 0 -> apply +5 -> restore 0
original +2 -> apply +5 -> restore +2
original +8 -> unchanged, record no mutation obligation
original -5 -> apply +5 -> restore -5
PID reuse -> refuse restore
path mismatch -> refuse restore
start-time mismatch -> refuse restore
state-save failure -> do not call setPriority
foreground replacement -> restore old family before applying new family
partial process failure -> preserve only unresolved obligations
```

- [ ] **Step 2: Implement compare-and-verify mutation**

Before each write:

```swift
let current = try inspector.process(pid: recorded.pid)
guard recorded.identity.matchesForMutation(current) else { throw MemoryInterventionError.identityMismatch }
```

After `setPriority`, read back with `priority(pid:)` and require exact confirmation.

- [ ] **Step 3: Keep a three-family hard cap in the controller too**

Even if the analyzer misbehaves, `apply(families:)` rejects input above 3.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter MemoryInterventionControllerTests
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryInterventionController.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift
git commit -m "feat: apply reversible memory scheduling policy"
```

---

### Task 9: Calibrate `taskpolicy`; enable I/O treatment only when exact restoration is proven

**Files:**
- Create: `scripts/memory_taskpolicy_calibration.sh`
- Create: `scripts/tests/test_memory_taskpolicy_calibration_source.sh`
- Create/Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTaskPolicyAdapter.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift`

**Interfaces:**
- Produces: `MemoryIOPolicyApplying`.

- [ ] **Step 1: Write the calibration source contract**

Require a disposable child process and forbid targeting arbitrary existing PIDs, sudo installation, launchd writes, or permanent service creation.

- [ ] **Step 2: Implement calibration with explicit confirmation**

Calibration sequence:

```text
launch disposable sleep/yes-like process
capture supported policy state
apply candidate taskpolicy treatment
verify
restore original policy
verify
terminate only the disposable child created by the calibration script
write JSON evidence
```

- [ ] **Step 3: HARD STOP for Catalina evidence**

If exact original policy cannot be read and restored, set `taskPolicy: false` and skip production adapter mutation.

- [ ] **Step 4: Implement the adapter only for a passed calibration**

```swift
public protocol MemoryIOPolicyApplying {
    func capture(pid: Int32) throws -> MemoryIOPolicyState
    func applyBackground(pid: Int32) throws
    func restore(pid: Int32, original: MemoryIOPolicyState) throws
    func verify(pid: Int32, expected: MemoryIOPolicyState) throws -> Bool
}
```

A capability-false adapter returns Unsupported without invoking `/usr/bin/taskpolicy`.

- [ ] **Step 5: Run tests and commit**

```bash
/bin/sh scripts/tests/test_memory_taskpolicy_calibration_source.sh
cd app/CatalinaPerformance
swift test --filter MemoryInterventionControllerTests
cd ../..
git add scripts/memory_taskpolicy_calibration.sh scripts/tests/test_memory_taskpolicy_calibration_source.sh \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift
git commit -m "feat: gate memory I/O policy behind Catalina calibration"
```

---

### Task 10: Build the Memory Management coordinator and integrate it with the existing 2-second session lifecycle

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementCoordinator.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/ProductionSessionMetricsCollector.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementCoordinatorTests.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionMetricIntegrationTests.swift`

**Interfaces:**
- `SessionMetricSnapshot.memoryManagement` carries telemetry/status.
- `PerformanceSessionCoordinator` forwards every completed 2-second snapshot to `MemoryManagementCoordinator.ingest(...)`.

- [ ] **Step 1: Write coordinator tests**

Required cases:

```text
Healthy -> no candidate mutation
3 High samples -> apply up to 3
2 Critical samples -> apply up to 3, no escalation beyond +5
5 Healthy after intervention -> restore all
foreground family -> immediate restore
App Priority target -> immediate restore
OFF -> immediate restore regardless healthy count
Emergency Restore -> immediate restore
telemetry insufficient while active -> stop admitting and restore conservatively
Background Service recheck request never overrides resumedByUser
```

- [ ] **Step 2: Add memory telemetry to `SessionMetricSnapshot` with backward-compatible decoding**

Use optional fields/defaults so schema-1 dashboard records without Memory Management still decode.

- [ ] **Step 3: Wire the collector**

`SessionMetricsCollector` receives optional `memoryTelemetryCollector: MemoryTelemetryCollecting?` and captures it in the same call as CPU/memory/swap/WindowServer. Do not add a timer.

- [ ] **Step 4: Wire the session coordinator**

After each successful snapshot capture, call `memoryManagementCoordinator.ingest(snapshot:...)` on a non-main queue. UI updates remain main-thread only.

- [ ] **Step 5: Add a narrow Background Service recheck callback**

The callback requests the existing coordinator to rescan its approved catalog; it must not introduce labels or undo `.resumedByUser` categories.

- [ ] **Step 6: Run focused tests and commit**

```bash
swift test --filter MemoryManagementCoordinatorTests
swift test --filter MemorySessionMetricIntegrationTests
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementCoordinator.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementCoordinatorTests.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionMetricIntegrationTests.swift
git commit -m "feat: integrate adaptive memory management with sessions"
```

---

### Task 11: Persist session aggregates and add the dedicated Memory / Swap dashboard section

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionRecorder.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionDashboardPresentationTests.swift`
- Modify: `scripts/tests/test_session_dashboard_ui_source.sh`

**Interfaces:**
- Produces: `MemorySessionAggregate` and `memoryRows` on `SessionDashboardViewModel`.

- [ ] **Step 1: Write presentation tests first**

Active view must show:

```text
State
Physical Used
Available
Compressed
Compression Growth
Swap Used
Swap Growth
Swap In
Swap Out
Page-Out Activity
Managed Workloads
I/O Policy
```

Completed view must show baseline/max/peak/net-growth/time-in-state/intervention-count/restoration evidence from the spec.

- [ ] **Step 2: Add aggregate recording**

Record:

```swift
baselineState
maximumState
baselineCompressedBytes
peakCompressedBytes
peakCompressionGrowthBytesPerSecond
baselineSwapBytes
peakSwapBytes
netSwapGrowthBytes
peakSwapInBytesPerSecond
peakSwapOutBytesPerSecond
healthySeconds
elevatedSeconds
highSeconds
criticalSeconds
interventionEpisodeCount
managedFamilyNames
longestInterventionDuration
```

Do not infer averages from unavailable readings.

- [ ] **Step 3: Add a dedicated Memory / Swap section in AppKit**

Follow the existing Graphics / WindowServer section structure. Do not place all rows into the generic System list.

- [ ] **Step 4: Run presentation/source tests and commit**

```bash
swift test --filter MemorySessionDashboardPresentationTests
cd ../..
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
git add app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore \
  app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionDashboardPresentationTests.swift \
  scripts/tests/test_session_dashboard_ui_source.sh
git commit -m "feat: report memory pressure management in dashboard"
```

---

### Task 12: Wire Performance Mode ON/OFF, foreground protection, Advanced status, and Emergency Restore

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Modify: `app/CatalinaPerformance/Package.swift`
- Modify: `scripts/package_app.sh`
- Create: `scripts/tests/test_memory_management_ui_source.sh`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementCoordinatorTests.swift`

**Interfaces:**
- Main app constructs `MemoryManagementCoordinator` once and injects it into the session collector/coordinator lifecycle.
- Advanced UI receives `MemoryManagementStatusSnapshot` only; no tuning sliders.

- [ ] **Step 1: Add source-contract assertions before AppKit edits**

Require the Advanced section strings:

```text
Memory Pressure Management
Automatically active with Performance Mode.
CPU deprioritization: nice +5
Maximum managed workloads: 3
```

Reject UI controls that alter nice value, family cap, swap limit, or VM thresholds.

- [ ] **Step 2: Add `CatalinaPerformanceMemoryCore` import and production construction in `main.swift`**

Create state under:

```swift
AdvancedPreferences.configDirectoryURL
    .appendingPathComponent("memory_management", isDirectory: true)
```

- [ ] **Step 3: Integrate ON lifecycle**

Before activation completes, call memory stale-state recovery. New interventions are allowed only after Performance Mode is active and the baseline/confirmation rules pass.

- [ ] **Step 4: Integrate OFF and Emergency Restore**

Before dashboard finalization is declared complete, call `restoreAll(reason:)`. If unresolved records remain, surface recovery-required status and retain state.

- [ ] **Step 5: Add foreground/App Priority conflict notifications**

Use AppKit frontmost-application identity on the main thread, pass only immutable identity into the memory coordinator, and restore a managed family before it can become an App Priority target.

- [ ] **Step 6: Replace the old read-only Memory / Storage description with authoritative Memory Pressure Management status**

Keep the manual storage report button if desired, but clearly separate disk-space diagnostics from the new automatic memory subsystem.

- [ ] **Step 7: Run source and focused tests**

```bash
/bin/sh scripts/tests/test_memory_management_ui_source.sh
cd app/CatalinaPerformance
swift test --filter MemoryManagementCoordinatorTests
swift build --product CatalinaPerformance
cd ../..
```

- [ ] **Step 8: Commit**

```bash
git add app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift \
  app/CatalinaPerformance/Package.swift scripts/package_app.sh \
  scripts/tests/test_memory_management_ui_source.sh
git commit -m "feat: wire memory management into Performance Mode"
```

---

### Task 13: Full regression, Catalina runtime validation, and evidence-based acceptance

**Files:**
- Modify: `docs/TESTING_CHECKLIST.md`
- Create: `docs/MEMORY_PRESSURE_RUNTIME_CHECKLIST.md`
- Modify any tests only to fix genuine failures uncovered here.

**Interfaces:**
- Produces final acceptance evidence; no new feature scope.

- [ ] **Step 1: Run all source-safety checks**

```bash
cd ~/Desktop/CatalinaPerformance
/bin/sh scripts/tests/test_memory_vm_probe_source.sh
/bin/sh scripts/tests/test_memory_taskpolicy_calibration_source.sh
/bin/sh scripts/tests/test_memory_management_ui_source.sh
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
/bin/sh scripts/tests/test_foreground_session.sh all
/bin/sh scripts/tests/test_advanced_layout_source.sh
/bin/sh scripts/tests/test_app_priority_wrappers.sh
/bin/sh scripts/tests/test_app_priority_ui_source.sh
/bin/sh scripts/tests/test_catalina_process_support_source.sh
/bin/sh scripts/tests/test_background_service_probe.sh
/bin/sh scripts/tests/test_background_service_settings.sh
/bin/sh scripts/tests/test_background_service_wrappers.sh
/bin/sh scripts/tests/test_background_service_ui_source.sh
/bin/sh scripts/tests/test_windowserver_pressure_source.sh
```

- [ ] **Step 2: Run the complete Catalina Swift suite and both existing products**

```bash
cd app/CatalinaPerformance
rm -rf .build
swift test
swift build --product CatalinaPerformance
swift build --product CatalinaPerformancePriorityAgent
cd ../..
git diff --check
```

Expected: zero test failures; warnings must be reviewed but do not count as passes if they indicate correctness issues.

- [ ] **Step 3: Package and launch**

```bash
pkill -x CatalinaPerformance 2>/dev/null || true
rm -rf build
./scripts/package_app.sh
open ./build/CatalinaPerformance.app
```

- [ ] **Step 4: Validate idle/normal conditions do not intervene**

Run Performance Mode for at least 2 minutes under ordinary browsing. Confirm:

```text
State Healthy or Elevated
Managed Workloads 0
No nice changes caused by Memory Management
Historical nonzero swap alone does not trigger action
```

- [ ] **Step 5: Validate controlled pressure lifecycle**

Create controlled memory pressure without risking data loss. Confirm:

```text
Healthy -> Elevated -> High
3 High samples before intervention
<= 3 qualifying background families
nice +5 verified
foregrounding a managed app restores it immediately
5 Healthy samples restores all remaining families
```

- [ ] **Step 6: Validate conflicts and recovery**

Confirm:

```text
App Priority target is never deprioritized
Background-service resumedByUser categories remain resumed
Performance Mode OFF restores immediately
Emergency Restore retries valid unresolved records
PID reuse is refused
relaunch with stale state restores or preserves unresolved evidence safely
```

- [ ] **Step 7: Compare performance evidence**

Record repeated equivalent workloads and compare:

```text
swap growth
swap-out rate
compression growth
time High/Critical
UI responsiveness
workload completion time
```

Do not claim benefit solely because intervention occurred.

- [ ] **Step 8: Update runtime docs with actual Catalina results and commit**

```bash
git add docs/TESTING_CHECKLIST.md docs/MEMORY_PRESSURE_RUNTIME_CHECKLIST.md
git commit -m "docs: validate Catalina memory pressure management"
```

---

## Final Acceptance Criteria

Memory Pressure & Swap Management 1.0 is complete only when all of the following are true:

1. Catalina VM counters used by production have verified units and behavior on the target Catalina 10.15.7 Mac.
2. Rate constants are static reviewed Catalina constants, not guessed runtime heuristics.
3. A single abnormal sample cannot mutate anything.
4. High/Critical confirmation and five-sample Healthy recovery behave exactly as specified.
5. No more than three qualifying families are ever managed.
6. Foreground and App Priority families are restored before exclusion transitions complete.
7. Every mutation is preceded by atomic persisted recovery state.
8. Nice values restore exactly, including negative and nonzero originals.
9. `taskpolicy` remains disabled unless exact calibration succeeds.
10. OFF, Emergency Restore, failed activation, and stale-session recovery share the same restore-first policy.
11. Unavailable telemetry is never presented or classified as zero.
12. Dashboard distinguishes RAM usage from active pressure and historical swap from swap growth.
13. No automatic application termination, swap disabling, `purge`, VM/kernel mutation, arbitrary daemon unloading, or protected-service mutation exists.
14. Full Catalina Swift tests/build/package pass and the real ON/OFF runtime lifecycle is validated.
15. Performance claims are based on repeated before/after evidence, not feature activation alone.
