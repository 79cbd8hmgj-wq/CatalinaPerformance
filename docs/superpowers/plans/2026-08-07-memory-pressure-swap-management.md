# Memory Pressure & Swap Management 1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Catalina-specific memory-pressure manager that detects sustained VM contention, ranks verified noncritical background application families, temporarily applies nice `+5` and only calibrated reversible I/O/background policy to at most three families, and restores their exact original state automatically.

**Architecture:** Add a new `CatalinaPerformanceMemoryCore` target for telemetry, classification, family analysis, desired-state generation, persistence models, and presentation-safe status. Extend `CatalinaProcessSupport` with read-only VM counters and feed them through the existing 2-second Performance Session collector. Because restoring a process from nice `+5` to its original value may require privilege on Darwin, add a session-scoped `CatalinaPerformanceMemoryAgent` that is started and stopped inside the existing administrator-authorized Performance Mode wrapper flow; it persists exact root-owned mutation state before changing anything and consumes only validated user-owned desired-state records. No permanent LaunchDaemon/helper is installed.

**Tech Stack:** Swift 5.2, macOS Catalina 10.15.7, AppKit, Foundation, SwiftPM, C Darwin APIs (`host_statistics64`, `sysctl`, `libproc`), existing administrator wrapper scripts, existing shell test harness.

## Global Constraints

- macOS minimum remains Catalina 10.15; compile with Xcode 12.4-era Swift.
- Reuse the existing 2-second Performance Session cadence for VM sampling; the privileged agent must not collect independent VM telemetry.
- High requires 3 consecutive High candidates; Critical requires 2 consecutive Critical candidates; recovery requires 5 consecutive Healthy samples.
- A family must remain background for 3 consecutive samples before eligibility.
- Minimum family size is `max(256 MB, 5% of physical RAM)`.
- Manage at most 3 families.
- CPU target is nice `+5`; never increase a process's priority relative to its pre-intervention state.
- `taskpolicy` remains Unsupported until Catalina calibration proves capture, apply, verify, exact restore, and verify-restored behavior on a disposable process.
- Never mutate foreground apps, the App Priority target, CatalinaPerformance, WindowServer, Finder, Dock, SystemUIServer, loginwindow, launchd, kernel_task, root-owned processes, AirDrop/network/Bluetooth/audio/security infrastructure, or unverifiable identities.
- Unavailable telemetry is never zero.
- The privileged agent must persist exact restoration state before mutation.
- PID reuse or identity mismatch means do not touch.
- No app termination, swap disabling, swap-file deletion, `purge`, VM/kernel tuning, arbitrary daemon unloading, SMC/MSR writes, kexts, or SIP changes.
- Preserve AirDrop and Background Service Suppression `.resumedByUser` decisions.
- Performance Mode OFF and Emergency Restore bypass hysteresis and request immediate exact restoration.
- No permanent privileged helper, LaunchDaemon, login item, or new authorization mechanism; reuse the existing administrator-authorized wrapper lifecycle.

---

## File Structure

### New production files

- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryModels.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryCollector.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryPressureClassifier.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryProcessFamilyAnalyzer.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementStateModels.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryDesiredStateStore.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryAgentStateStore.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryInterventionController.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTaskPolicyAdapter.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryAgentService.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementCoordinator.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryAgent/main.swift`
- `scripts/lib/memory_management_wrapper_common.sh`
- `scripts/memory_vm_probe.sh`
- `scripts/memory_taskpolicy_calibration.sh`
- `scripts/tests/test_memory_vm_probe_source.sh`
- `scripts/tests/test_memory_taskpolicy_calibration_source.sh`
- `scripts/tests/test_memory_management_wrappers.sh`
- `scripts/tests/test_memory_management_ui_source.sh`

### New tests

- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/CatalinaMemoryCapabilitiesTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryPressureClassifierTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryProcessFamilyAnalyzerTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryDesiredStateStoreTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryAgentStateStoreTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryAgentServiceTests.swift`
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
- `scripts/performance_on_with_priority.sh`
- `scripts/performance_off_with_priority.sh`
- `scripts/emergency_restore_with_priority.sh`
- `scripts/package_app.sh`
- `scripts/tests/test_session_dashboard_ui_source.sh`
- `docs/TESTING_CHECKLIST.md`

---

### Task 1: Add Memory Core and stable public models

**Files:**
- Modify: `app/CatalinaPerformance/Package.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryModels.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift`

**Interfaces:**
- Produces `MemoryPressureState`, `MemoryVMCounters`, `MemoryTelemetryRates`, `MemoryTelemetrySnapshot`, `MemoryManagementStatusSnapshot`.

- [ ] **Step 1: Write failing tests**

```swift
func testMemoryPressureStateOrdersBySeverity() {
    XCTAssertLessThan(MemoryPressureState.healthy, .elevated)
    XCTAssertLessThan(MemoryPressureState.elevated, .high)
    XCTAssertLessThan(MemoryPressureState.high, .critical)
}

func testUnavailableRateRemainsNil() {
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

- [ ] **Step 2: Verify failure**

```bash
cd app/CatalinaPerformance
swift test --filter MemoryTelemetryModelsTests
```

Expected: FAIL because the target/types do not exist.

- [ ] **Step 3: Add target and explicit public models**

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

Add `CatalinaPerformanceMemoryCore` to main-app and dashboard-core dependencies.

Define `MemoryVMCounters` with explicit `UInt64?` fields for unsupported counters and an explicit public initializer. Never use sentinel zero to mean unsupported.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter MemoryTelemetryModelsTests
git add app/CatalinaPerformance/Package.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryModels.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift
git commit -m "feat: add memory management core models"
```

---

### Task 2: Extend native Catalina VM telemetry and derive rates safely

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaProcessSupport/include/CatalinaProcessSupport.h`
- Modify: `app/CatalinaPerformance/Sources/CatalinaProcessSupport/CatalinaProcessSupport.c`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryCollector.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift`

**Interfaces:**
- Produces `MemoryTelemetryCollecting.capture(at:) -> MemoryTelemetrySnapshot`.
- Native boundary: `cp_read_vm_memory_info(CPVMMemoryInfo *)`.

- [ ] **Step 1: Write monotonic-counter tests**

Use this concrete rate case:

```swift
XCTAssertEqual(
    MemoryRateCalculator.deltaRate(
        previous: 100,
        current: 140,
        elapsed: 2.0,
        unitBytes: 4096
    ),
    81_920
)
XCTAssertNil(
    MemoryRateCalculator.deltaRate(
        previous: 100,
        current: 90,
        elapsed: 2.0,
        unitBytes: 4096
    )
)
```

- [ ] **Step 2: Add the read-only C boundary**

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
    uint64_t availabilityMask;
} CPVMMemoryInfo;

int32_t cp_read_vm_memory_info(CPVMMemoryInfo *output);
```

`availabilityMask` distinguishes a supported counter whose value is zero from an unsupported counter. Non-Apple returns `-ENOTSUP`.

- [ ] **Step 3: Implement collector**

```swift
public protocol MemoryTelemetryCollecting {
    func capture(at date: Date) -> MemoryTelemetrySnapshot
}

public final class DarwinMemoryTelemetryCollector: MemoryTelemetryCollecting {
    private var previousDate: Date?
    private var previousCounters: MemoryVMCounters?
    public init() {}
    public func capture(at date: Date) -> MemoryTelemetrySnapshot
}
```

The implementation reads native counters once, calculates deltas from the previous successful reading, and updates previous state only after validating the current sample. Use `{ Double($0) }` for `UInt64` conversion; never `value.map(Double.init)`.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MemoryTelemetryModelsTests
swift test --filter ProcessSupportSmokeTests
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

**Interfaces:** Produces evidence only; no rate constant is approved here.

- [ ] **Step 1: Write source contract before the probe**

```sh
grep -F '/usr/bin/vm_stat' scripts/memory_vm_probe.sh
grep -F '/usr/bin/memory_pressure' scripts/memory_vm_probe.sh
grep -F 'vm.swapusage' scripts/memory_vm_probe.sh
! grep -Eq '(^|[[:space:]])(purge|killall|launchctl[[:space:]]+(bootout|unload)|sysctl[[:space:]]+-w|rm[[:space:]].*swap)' scripts/memory_vm_probe.sh
```

- [ ] **Step 2: Confirm source test fails before implementation**

```bash
/bin/sh scripts/tests/test_memory_vm_probe_source.sh
```

- [ ] **Step 3: Implement probe**

Capture `sw_vers`, `uname -a`, `sysctl hw.memsize`, `sysctl vm.swapusage`, `vm_stat`, `memory_pressure`, selected read-only `vm.*` values, and three `vm_stat` captures separated by 2 seconds. Never use sudo or write a preference/sysctl.

- [ ] **Step 4: Verify and commit**

```bash
/bin/sh scripts/tests/test_memory_vm_probe_source.sh
git add scripts/memory_vm_probe.sh scripts/tests/test_memory_vm_probe_source.sh docs/TESTING_CHECKLIST.md
git commit -m "test: add Catalina VM capability probe"
```

- [ ] **Step 5: HARD STOP for Catalina evidence**

```bash
/bin/sh scripts/memory_vm_probe.sh \
  --output "$HOME/Desktop/catalina-10.15.7-memory-vm-probe.txt"
```

Do not continue to Task 4 until evidence review records supported counters, units, monotonic behavior, and observed idle/pressure ranges.

---

### Task 4: Freeze reviewed Catalina capabilities and static thresholds

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/CatalinaMemoryCapabilitiesTests.swift`
- Modify: `docs/TESTING_CHECKLIST.md`

**Interfaces:** Produces `CatalinaMemoryCapabilities.current` and `MemoryPressureThresholds.catalina10157`.

- [ ] **Step 1: Encode capability flags only from reviewed probe evidence**

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

`taskPolicy` is `false` in this task; Task 10 may change it only after independent calibration.

- [ ] **Step 2: Test approved fixed percentages**

```swift
XCTAssertEqual(profile.availableModerateFraction, 0.15)
XCTAssertEqual(profile.availableStrongFraction, 0.08)
XCTAssertEqual(profile.availableSevereFraction, 0.05)
XCTAssertEqual(profile.compressedModerateFraction, 0.20)
XCTAssertEqual(profile.compressedStrongFraction, 0.30)
```

Each rate threshold gets an exact assertion using the reviewed value from the Task 3 evidence-review commit. The implementer must not invent an unreviewed number.

- [ ] **Step 3: Run and commit**

```bash
swift test --filter CatalinaMemoryCapabilitiesTests
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/CatalinaMemoryCapabilitiesTests.swift \
  docs/TESTING_CHECKLIST.md
git commit -m "feat: calibrate Catalina memory pressure profile"
```

---

### Task 5: Implement the multi-signal classifier and recovery hysteresis

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryPressureClassifier.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryPressureClassifierTests.swift`

**Interfaces:** Consumes `MemoryTelemetrySnapshot` and `MemoryPressureThresholds`; produces `MemoryPressureEvaluation`.

- [ ] **Step 1: Write exact state-machine tests**

```swift
func testSingleHighCandidateDoesNotIntervene()
func testThreeHighCandidatesConfirmHigh()
func testTwoCriticalCandidatesConfirmCritical()
func testThreeElevatedCandidatesConfirmElevated()
func testFiveHealthySamplesAfterInterventionRequestsRestore()
func testElevatedSampleResetsHealthyRecoveryCounter()
func testStableHistoricalSwapDoesNotCreatePressureEvidence()
func testUnavailableMetricContributesNoEvidence()
```

- [ ] **Step 2: Implement named evidence flags**

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

- [ ] **Step 3: Implement exact confirmation counters**

No intervention request before 3 High or 2 Critical candidates. Any non-Healthy sample resets the Healthy recovery counter.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MemoryPressureClassifierTests
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryPressureClassifier.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryPressureClassifierTests.swift
git commit -m "feat: classify sustained memory pressure"
```

---

### Task 6: Add resident-memory inspection and verified family ranking

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformancePriorityCore/AppPriorityProcessInspector.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryProcessFamilyAnalyzer.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryProcessFamilyAnalyzerTests.swift`

**Interfaces:** Add `AppPriorityProcessResourceInspecting.residentBytes(pid:)`; produce deterministic `[MemoryProcessFamilyCandidate]`.

- [ ] **Step 1: Add focused resource protocol**

```swift
public protocol AppPriorityProcessResourceInspecting {
    func residentBytes(pid: Int32) throws -> UInt64
}
```

`DarwinAppPriorityProcessInspector` conforms using `cp_read_process_resources`.

- [ ] **Step 2: Write analyzer tests**

Cover same-user grouping, 3-sample background eligibility, frontmost exclusion, App Priority exclusion, root exclusion, protected exact-path exclusion, significance threshold, memory-growth tie-break, deterministic ordering, maximum three selection, and recently-foregrounded penalty.

- [ ] **Step 3: Implement protection policy and family construction**

Use exact process identity/ancestry plus application identity; never authorize mutation from fuzzy process-name matching. If frontmost identity is unavailable, admit no new family.

- [ ] **Step 4: Implement deterministic ranking**

Use explicit ordered factors: memory tier, growth tier, sustained-background sample count, canonical family identifier. No randomization or opaque adaptive score.

- [ ] **Step 5: Run and commit**

```bash
swift test --filter MemoryProcessFamilyAnalyzerTests
git add app/CatalinaPerformance/Sources/CatalinaPerformancePriorityCore/AppPriorityProcessInspector.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryProcessFamilyAnalyzer.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryProcessFamilyAnalyzerTests.swift
git commit -m "feat: rank safe background memory families"
```

---

### Task 7: Define desired-state and root-owned restoration-state models/stores

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementStateModels.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryDesiredStateStore.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryAgentStateStore.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryDesiredStateStoreTests.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryAgentStateStoreTests.swift`

**Interfaces:**
- User-owned desired-state path: `~/Library/Application Support/CatalinaPerformance/memory_management/desired-state.json`.
- Privileged runtime root: `/var/run/CatalinaPerformance/<uid>/memory_management/`.
- Produces `MemoryDesiredState`, `MemoryAgentRuntimeState`, `MemoryAgentStatus`.

- [ ] **Step 1: Define exact desired-state model**

```swift
public struct MemoryDesiredState: Codable, Equatable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let sessionIdentifier: String
    public let requestingUID: UInt32
    public let generation: UInt64
    public let shouldStopAndRestore: Bool
    public let families: [MemoryDesiredFamily]
}
```

Each desired process contains PID, UID, parent PID, executable path, start seconds/microseconds, current observed nice, family identifier, and requested nice target.

- [ ] **Step 2: Write desired-state safety tests**

Require 0600 file, 0700 directory, atomic temp+fsync+rename, no symlink, max 1 MB, schema validation, monotonically increasing generation, and at most three families.

- [ ] **Step 3: Define root-owned runtime state**

`MemoryAgentRuntimeState` stores exact original nice, applied nice, original/apply I/O policy when supported, process identity, session ID, and unresolved restoration flag for every mutation.

- [ ] **Step 4: Write agent-state safety tests**

Mirror existing `AppPriorityStateStore` security patterns: validated runtime root, atomic writes, lock file, status file, stop request, corrupt-state handling, unresolved state preservation.

- [ ] **Step 5: Run and commit**

```bash
swift test --filter MemoryDesiredStateStoreTests
swift test --filter MemoryAgentStateStoreTests
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementStateModels.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryDesiredStateStore.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryAgentStateStore.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryDesiredStateStoreTests.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryAgentStateStoreTests.swift
git commit -m "feat: persist memory desired and restoration state"
```

---

### Task 8: Implement privileged exact nice intervention and restoration

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryInterventionController.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift`

**Interfaces:** Consumes `AppPriorityProcessInspecting`, `AppPriorityPriorityMutating`, `MemoryAgentStateStoring`; produces `reconcile(desired:)` and `restoreAll()`.

- [ ] **Step 1: Write mutation tests**

Verify `0 -> +5 -> 0`, `+2 -> +5 -> +2`, existing `+8` unchanged, `-5 -> +5 -> -5`, PID/path/start-time mismatch refusal, state-save failure before write, restore-before-family-replacement, maximum three families, and partial failure retaining unresolved obligations.

- [ ] **Step 2: Implement reverify-before-write**

```swift
let current = try inspector.process(pid: recorded.pid)
guard recorded.identity.matchesForMutation(current) else {
    throw MemoryInterventionError.identityMismatch
}
```

The controller writes the root-owned runtime record before `setPriority`, then reads priority back after the write and requires exact confirmation.

- [ ] **Step 3: Implement restore-first reconciliation**

When a previously managed family disappears from desired state, restore it before applying a replacement family. A reused PID is never restored.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MemoryInterventionControllerTests
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryInterventionController.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift
git commit -m "feat: apply privileged reversible memory scheduling"
```

---

### Task 9: Add the session-scoped privileged Memory Agent

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryAgentService.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryAgent/main.swift`
- Modify: `app/CatalinaPerformance/Package.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryAgentServiceTests.swift`

**Interfaces:**
- Commands: `validate --uid`, `start --uid`, `monitor --uid --session`, `stop-and-restore --uid`, `restore --uid`, `status --uid`.
- Mirrors the proven `AppPriorityAgentService` lifecycle but validates Memory Management desired state and protected process policy.

- [ ] **Step 1: Write command parser/service tests**

Cover malformed UID/session rejection, console-UID mismatch, desired-state symlink/owner/mode rejection, start lock, monitor lock, start timeout, stop request, direct restore after monitor death, and status reporting.

- [ ] **Step 2: Add executable target/product**

```swift
.executable(name: "CatalinaPerformanceMemoryAgent", targets: ["CatalinaPerformanceMemoryAgent"])
```

Target depends on `CatalinaPerformanceMemoryCore`.

- [ ] **Step 3: Implement service start/monitor pattern**

Use the existing App Priority agent's direct `Process` launch pattern; do not use `/usr/bin/nohup`. The monitor reads desired-state generations, validates every listed process as same-user/nonprotected, and calls `MemoryInterventionController.reconcile`.

- [ ] **Step 4: Fail safe on missing/invalid desired state**

If desired state becomes unreadable or invalid while mutations are outstanding, stop admitting changes and restore outstanding valid records. Never interpret missing desired state as permission to leave processes deprioritized indefinitely.

- [ ] **Step 5: Run and commit**

```bash
swift test --filter MemoryAgentServiceTests
swift build --product CatalinaPerformanceMemoryAgent
git add app/CatalinaPerformance/Package.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryAgentService.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryAgent/main.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryAgentServiceTests.swift
git commit -m "feat: add session-scoped memory management agent"
```

---

### Task 10: Calibrate `taskpolicy` and gate I/O treatment

**Files:**
- Create: `scripts/memory_taskpolicy_calibration.sh`
- Create: `scripts/tests/test_memory_taskpolicy_calibration_source.sh`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTaskPolicyAdapter.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift`

**Interfaces:** Produces `MemoryIOPolicyApplying`.

- [ ] **Step 1: Write calibration source contract**

Require a disposable child created by the script. Reject arbitrary target PID input, permanent helpers, launchd writes, and unrelated process killing.

- [ ] **Step 2: Implement calibration sequence**

Launch disposable child, capture policy state, apply candidate background/I/O policy, verify, restore captured state, verify exact restoration, terminate only the disposable child, and write JSON evidence.

- [ ] **Step 3: HARD STOP for Catalina evidence**

If exact state capture or exact restoration cannot be proven, keep `CatalinaMemoryCapabilities.current.taskPolicy == false`; production uses nice `+5` only.

- [ ] **Step 4: Implement adapter only for passed calibration**

```swift
public protocol MemoryIOPolicyApplying {
    func capture(pid: Int32) throws -> MemoryIOPolicyState
    func applyBackground(pid: Int32) throws
    func restore(pid: Int32, original: MemoryIOPolicyState) throws
    func verify(pid: Int32, expected: MemoryIOPolicyState) throws -> Bool
}
```

Capability false returns Unsupported without invoking `/usr/bin/taskpolicy`.

- [ ] **Step 5: Run and commit**

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

### Task 11: Build the user-side Memory Management coordinator and session integration

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementCoordinator.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/ProductionSessionMetricsCollector.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementCoordinatorTests.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionMetricIntegrationTests.swift`

**Interfaces:** `SessionMetricSnapshot.memoryManagement` is optional for backward-compatible decoding. The coordinator writes validated desired state; it never writes process priorities directly.

- [ ] **Step 1: Write coordinator tests**

Verify Healthy no-op, 3 High desired-state admission, 2 Critical admission without escalation, 5 Healthy desired-state removal, immediate foreground removal, immediate App Priority-target removal, OFF/Emergency stop-and-restore request, insufficient telemetry causing conservative desired-state removal, and Background Service recheck preserving `.resumedByUser`.

- [ ] **Step 2: Add optional memory snapshot with decode default**

Old dashboard JSON without `memoryManagement` must still decode.

- [ ] **Step 3: Inject `MemoryTelemetryCollecting?` into `SessionMetricsCollector`**

Capture memory telemetry in the same existing 2-second sample. No new VM timer.

- [ ] **Step 4: Implement desired-state generation**

Only confirmed High/Critical and verified candidates may enter desired state. Removing a foreground/App Priority family increments generation immediately so the privileged monitor restores it promptly.

- [ ] **Step 5: Add narrow Background Service recheck callback**

It may request rescan of the existing approved catalog only; it cannot authorize new labels or reverse user resume decisions.

- [ ] **Step 6: Run and commit**

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

### Task 12: Add session aggregates and dedicated Memory / Swap dashboard reporting

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionRecorder.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionDashboardPresentationTests.swift`
- Modify: `scripts/tests/test_session_dashboard_ui_source.sh`

**Interfaces:** Produces `MemorySessionAggregate` and `memoryRows` on `SessionDashboardViewModel`.

- [ ] **Step 1: Write presentation tests**

Active rows: State, Physical Used, Available, Compressed, Compression Growth, Swap Used, Swap Growth, Swap In, Swap Out, Page-Out Activity, Managed Workloads, I/O Policy.

Completed report: baseline/max state, baseline/peak compressed memory, peak compression growth, baseline/peak/net swap, peak swap-in/out, time Healthy/Elevated/High/Critical, intervention episodes, managed family names, longest intervention duration, restoration result.

- [ ] **Step 2: Add aggregate recording without zero fabrication**

Only available values contribute to peaks/rates. Use explicit `UInt64 -> Double` closures.

- [ ] **Step 3: Add dedicated AppKit section**

Follow the existing Graphics / WindowServer section pattern; do not overload the generic System rows.

- [ ] **Step 4: Run and commit**

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

### Task 13: Start/stop the Memory Agent inside the existing authorized wrappers

**Files:**
- Create: `scripts/lib/memory_management_wrapper_common.sh`
- Modify: `scripts/performance_on_with_priority.sh`
- Modify: `scripts/performance_off_with_priority.sh`
- Modify: `scripts/emergency_restore_with_priority.sh`
- Create: `scripts/tests/test_memory_management_wrappers.sh`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Modify: `scripts/package_app.sh`

**Interfaces:** Environment adds `CATALINA_PERFORMANCE_MEMORY_AGENT_PATH` and `CATALINA_PERFORMANCE_MEMORY_DESIRED_STATE_FILE`.

- [ ] **Step 1: Write wrapper tests before production changes**

Require:

```text
ON: require memory agent -> validate -> core ON -> memory agent start
ON rollback: if memory agent start fails, stop/restore App Priority, restore core/background state, and fail
OFF: memory stop-and-restore runs even when App Priority is disabled
Emergency: memory stop-and-restore is attempted even if another subsystem restore fails
```

Reject `nohup`, permanent daemon installation, arbitrary executable paths, and missing UID validation.

- [ ] **Step 2: Add common wrapper helpers**

Mirror `app_priority_wrapper_common.sh`: validate requesting UID, require exact executable, shell-quote environment, and invoke only documented Memory Agent commands.

- [ ] **Step 3: Extend `ScriptRunner.scriptEnvironment()`**

Add bundled/development resolution for `CatalinaPerformanceMemoryAgent`, matching the existing `priorityAgentURL` resolution pattern.

- [ ] **Step 4: Package the memory agent**

`package_app.sh` copies `CatalinaPerformanceMemoryAgent` to `Contents/Resources/bin/` and verifies it is executable.

- [ ] **Step 5: Run and commit**

```bash
/bin/sh scripts/tests/test_memory_management_wrappers.sh
cd app/CatalinaPerformance
swift build --product CatalinaPerformanceMemoryAgent
swift build --product CatalinaPerformance
cd ../..
git add scripts/lib/memory_management_wrapper_common.sh \
  scripts/performance_on_with_priority.sh scripts/performance_off_with_priority.sh \
  scripts/emergency_restore_with_priority.sh scripts/tests/test_memory_management_wrappers.sh \
  app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift scripts/package_app.sh
git commit -m "feat: integrate memory agent with authorized lifecycle"
```

---

### Task 14: Add Advanced status and complete foreground/App Priority lifecycle wiring

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Create: `scripts/tests/test_memory_management_ui_source.sh`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementCoordinatorTests.swift`

**Interfaces:** Advanced UI receives immutable `MemoryManagementStatusSnapshot`; no tuning sliders.

- [ ] **Step 1: Add UI source contract**

Require:

```text
Memory Pressure Management
Automatically active with Performance Mode.
CPU deprioritization: nice +5
Maximum managed workloads: 3
```

Reject controls for nice level, family cap, swap target, compressor target, or VM thresholds.

- [ ] **Step 2: Add production coordinator construction**

Desired-state directory:

```swift
AdvancedPreferences.configDirectoryURL
    .appendingPathComponent("memory_management", isDirectory: true)
```

Agent status path follows `/var/run/CatalinaPerformance/<uid>/memory_management/status.json`.

- [ ] **Step 3: Wire frontmost identity and App Priority conflict**

Read `NSWorkspace.shared.frontmostApplication` on main, convert to immutable bundle/path identity, and notify the memory coordinator. A family removed for foreground/App Priority reasons must be absent from desired state before UI reports it eligible again.

- [ ] **Step 4: Replace old Memory / Storage explanatory text**

Memory Pressure Management becomes authoritative for memory state. Keep the existing manual storage report as a separate disk diagnostic.

- [ ] **Step 5: Run and commit**

```bash
/bin/sh scripts/tests/test_memory_management_ui_source.sh
cd app/CatalinaPerformance
swift test --filter MemoryManagementCoordinatorTests
swift build --product CatalinaPerformance
cd ../..
git add app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift \
  scripts/tests/test_memory_management_ui_source.sh
git commit -m "feat: expose memory management status in Advanced"
```

---

### Task 15: Full regression and Catalina runtime acceptance

**Files:**
- Modify: `docs/TESTING_CHECKLIST.md`
- Create: `docs/MEMORY_PRESSURE_RUNTIME_CHECKLIST.md`

**Interfaces:** Final evidence only; no new feature scope.

- [ ] **Step 1: Run source-safety checks**

```bash
cd ~/Desktop/CatalinaPerformance
/bin/sh scripts/tests/test_memory_vm_probe_source.sh
/bin/sh scripts/tests/test_memory_taskpolicy_calibration_source.sh
/bin/sh scripts/tests/test_memory_management_wrappers.sh
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

- [ ] **Step 2: Run complete Catalina tests/builds**

```bash
cd app/CatalinaPerformance
rm -rf .build
swift test
swift build --product CatalinaPerformance
swift build --product CatalinaPerformancePriorityAgent
swift build --product CatalinaPerformanceMemoryAgent
cd ../..
git diff --check
```

- [ ] **Step 3: Package and launch**

```bash
pkill -x CatalinaPerformance 2>/dev/null || true
pkill -x CatalinaPerformanceMemoryAgent 2>/dev/null || true
rm -rf build
./scripts/package_app.sh
open ./build/CatalinaPerformance.app
```

- [ ] **Step 4: Validate ordinary load does not intervene**

Run Performance Mode at least 2 minutes. Historical nonzero swap without active growth must not manage any family while state is Healthy/Elevated.

- [ ] **Step 5: Validate controlled pressure lifecycle**

Confirm `Healthy -> Elevated -> High`, 3 High samples before desired-state admission, at most 3 families, privileged nice `+5` verification, immediate restoration when a managed app becomes foreground, and exact restoration after 5 Healthy samples.

- [ ] **Step 6: Validate privilege/restoration behavior**

Confirm the agent can restore `+5 -> 0`, `+5 -> +2`, and `+5 -> -5` when those were the recorded originals. Confirm agent crash followed by `restore --uid` uses root-owned runtime state and does not require trusting current desired state.

- [ ] **Step 7: Validate conflicts and recovery**

Confirm App Priority target exclusion, `.resumedByUser` preservation, OFF restore, Emergency Restore, PID-reuse refusal, invalid desired-state fail-safe restoration, and app relaunch/stale-session recovery.

- [ ] **Step 8: Compare repeated performance evidence**

Record swap growth, swap-out rate, compression growth, time High/Critical, UI responsiveness, and workload completion time. Do not claim benefit solely because intervention occurred.

- [ ] **Step 9: Document actual Catalina evidence and commit**

```bash
git add docs/TESTING_CHECKLIST.md docs/MEMORY_PRESSURE_RUNTIME_CHECKLIST.md
git commit -m "docs: validate Catalina memory pressure management"
```

---

## Final Acceptance Criteria

1. Production VM counters have verified units and behavior on Catalina 10.15.7.
2. Rate thresholds are reviewed static Catalina constants from the capability checkpoint.
3. One abnormal sample cannot mutate anything.
4. High/Critical confirmation and five-sample recovery are exact.
5. No more than three families are managed.
6. Foreground and App Priority conflicts are removed from desired state immediately and restored by the privileged agent before replacement.
7. The privileged agent persists root-owned exact restoration state before every mutation.
8. Nice values restore exactly, including negative and nonzero originals.
9. `taskpolicy` remains disabled unless exact calibration succeeds.
10. OFF, Emergency Restore, failed activation, monitor failure, and stale-session recovery share restore-first behavior.
11. Missing/invalid desired state never leaves outstanding valid mutations intentionally active.
12. Unavailable telemetry is never displayed or classified as zero.
13. Dashboard distinguishes high RAM usage from active pressure and historical swap from new swap growth.
14. No app termination, swap disabling, `purge`, VM/kernel mutation, arbitrary daemon unloading, or protected-service mutation exists.
15. No permanent privileged helper/LaunchDaemon is installed.
16. Full Catalina tests/build/package pass and the real ON/OFF lifecycle is validated.
17. Any performance claim is supported by repeated before/after evidence.
