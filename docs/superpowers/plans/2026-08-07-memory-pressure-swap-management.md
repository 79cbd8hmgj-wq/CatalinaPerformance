# Memory Pressure & Swap Management 1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Catalina-specific memory-pressure manager that detects sustained VM contention, ranks verified noncritical background application families, temporarily applies nice `+5` and only calibrated reversible I/O/background policy to at most three families, and restores their exact original state automatically.

**Architecture:** Add a new `CatalinaPerformanceMemoryCore` target for telemetry, classification, family analysis, persistence, and intervention policy. Extend `CatalinaProcessSupport` with read-only VM counters, feed them through the existing 2-second Performance Session collector, and require exact process identity plus persisted recovery state before mutation. Reuse existing App Priority process identity/mutation boundaries and AppKit lifecycle; do not add another high-frequency VM timer, permanent daemon, VM/kernel tuning, application killing, swap disabling, or `purge` behavior.

**Tech Stack:** Swift 5.2, macOS Catalina 10.15.7, AppKit, Foundation, SwiftPM, C Darwin APIs (`host_statistics64`, `sysctl`, `libproc`), existing shell test harness.

## Global Constraints

- macOS minimum remains Catalina 10.15; compile with Xcode 12.4-era Swift.
- Reuse the existing 2-second Performance Session cadence.
- High requires 3 consecutive High candidates; Critical requires 2 consecutive Critical candidates; recovery requires 5 consecutive Healthy samples.
- A family must remain background for 3 consecutive samples before eligibility.
- Minimum family size is `max(256 MB, 5% of physical RAM)`.
- Manage at most 3 families.
- CPU target is nice `+5`; never increase a process's priority relative to its current state.
- `taskpolicy` remains Unsupported until Catalina calibration proves capture, apply, verify, exact restore, and verify-restored behavior on a disposable process.
- Never mutate foreground apps, the App Priority target, CatalinaPerformance, WindowServer, Finder, Dock, SystemUIServer, loginwindow, launchd, kernel_task, root-owned processes, AirDrop/network/Bluetooth/audio/security infrastructure, or unverifiable identities.
- Unavailable telemetry is never zero.
- Persist exact recovery state before mutation.
- PID reuse or identity mismatch means do not touch.
- No app termination, swap disabling, swap-file deletion, `purge`, VM/kernel tuning, arbitrary daemon unloading, SMC/MSR writes, kexts, or SIP changes.
- Preserve AirDrop and Background Service Suppression `.resumedByUser` decisions.
- Performance Mode OFF and Emergency Restore bypass hysteresis and restore immediately.

---

## File Structure

### New production files

- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryModels.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryCollector.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryPressureClassifier.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryProcessFamilyAnalyzer.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementStateStore.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryInterventionController.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTaskPolicyAdapter.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementCoordinator.swift`
- `scripts/memory_vm_probe.sh`
- `scripts/memory_taskpolicy_calibration.sh`
- `scripts/tests/test_memory_vm_probe_source.sh`
- `scripts/tests/test_memory_taskpolicy_calibration_source.sh`
- `scripts/tests/test_memory_management_ui_source.sh`

### New tests

- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/CatalinaMemoryCapabilitiesTests.swift`
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

### Task 1: Add Memory Core and stable public models

**Files:**
- Modify: `app/CatalinaPerformance/Package.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTelemetryModels.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryTelemetryModelsTests.swift`

**Interfaces:**
- Produces: `MemoryPressureState`, `MemoryVMCounters`, `MemoryTelemetryRates`, `MemoryTelemetrySnapshot`, `MemoryManagedProcessRecord`, `MemoryManagedFamilyRecord`, `MemoryManagementStatusSnapshot`.

- [ ] **Step 1: Write failing model tests**

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

- [ ] **Step 3: Add target and models**

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

Add `CatalinaPerformanceMemoryCore` to the main executable and dashboard-core dependencies.

Define:

```swift
public enum MemoryPressureState: Int, Codable, Comparable {
    case healthy = 0
    case elevated = 1
    case high = 2
    case critical = 3

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

    public init(
        physicalBytes: UInt64,
        availableBytes: UInt64,
        compressedBytes: UInt64?,
        swapUsedBytes: UInt64,
        compressions: UInt64?,
        decompressions: UInt64?,
        pageIns: UInt64?,
        pageOuts: UInt64?,
        swapIns: UInt64?,
        swapOuts: UInt64?
    ) {
        self.physicalBytes = physicalBytes
        self.availableBytes = availableBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.compressions = compressions
        self.decompressions = decompressions
        self.pageIns = pageIns
        self.pageOuts = pageOuts
        self.swapIns = swapIns
        self.swapOuts = swapOuts
    }
}
```

Give every public model an explicit public initializer.

- [ ] **Step 4: Run tests**

```bash
swift test --filter MemoryTelemetryModelsTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/CatalinaPerformance/Package.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore \
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
- Produces: `MemoryTelemetryCollecting.capture(at:) -> MemoryTelemetrySnapshot`.
- Native boundary: `cp_read_vm_memory_info(CPVMMemoryInfo *)`.

- [ ] **Step 1: Write failing monotonic-counter tests**

```swift
func testRateCalculatorUsesPageSizedCounterDelta() {
    let previous = MemoryVMCounters(
        physicalBytes: 8_589_934_592,
        availableBytes: 2_147_483_648,
        compressedBytes: 1_073_741_824,
        swapUsedBytes: 268_435_456,
        compressions: 1_000,
        decompressions: 200,
        pageIns: 500,
        pageOuts: 100,
        swapIns: 20,
        swapOuts: 100
    )
    let current = MemoryVMCounters(
        physicalBytes: 8_589_934_592,
        availableBytes: 2_000_000_000,
        compressedBytes: 1_100_000_000,
        swapUsedBytes: 270_000_000,
        compressions: 1_100,
        decompressions: 210,
        pageIns: 520,
        pageOuts: 110,
        swapIns: 25,
        swapOuts: 140
    )
    let rates = MemoryRateCalculator.rates(
        previous: previous,
        current: current,
        elapsed: 2.0,
        pageSize: 4096
    )
    XCTAssertEqual(rates.swapOutBytesPerSecond, 81_920)
    XCTAssertEqual(rates.compressionBytesPerSecond, 204_800)
}

func testCounterRollbackProducesUnavailableRate() {
    XCTAssertNil(MemoryRateCalculator.deltaRate(previous: 100, current: 90, elapsed: 2.0, unitBytes: 4096))
}
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

Use `availabilityMask` bits to distinguish unsupported counters from real zero values. Non-Apple implementation returns `-ENOTSUP`.

- [ ] **Step 3: Implement collector and rate calculator**

```swift
public protocol MemoryTelemetryCollecting {
    func capture(at date: Date) -> MemoryTelemetrySnapshot
}

public final class DarwinMemoryTelemetryCollector: MemoryTelemetryCollecting {
    private var previousDate: Date?
    private var previousCounters: MemoryVMCounters?

    public init() {}

    public func capture(at date: Date) -> MemoryTelemetrySnapshot {
        let native = readNativeCounters(at: date)
        let rates = deriveRates(current: native, at: date)
        previousDate = date
        previousCounters = native
        return MemoryTelemetrySnapshot(capturedAt: date, counters: native, rates: rates)
    }
}
```

Use `{ Double($0) }` for `UInt64` conversion; never `value.map(Double.init)`.

- [ ] **Step 4: Run focused tests**

```bash
swift test --filter MemoryTelemetryModelsTests
swift test --filter ProcessSupportSmokeTests
```

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

**Interfaces:** Produces evidence only; no production rate constants are approved here.

- [ ] **Step 1: Write the source contract first**

```sh
grep -F '/usr/bin/vm_stat' scripts/memory_vm_probe.sh
grep -F '/usr/bin/memory_pressure' scripts/memory_vm_probe.sh
grep -F 'vm.swapusage' scripts/memory_vm_probe.sh
! grep -Eq '(^|[[:space:]])(purge|killall|launchctl[[:space:]]+(bootout|unload)|sysctl[[:space:]]+-w|rm[[:space:]].*swap)' scripts/memory_vm_probe.sh
```

- [ ] **Step 2: Verify failure before the probe exists**

```bash
/bin/sh scripts/tests/test_memory_vm_probe_source.sh
```

- [ ] **Step 3: Implement the probe**

Capture `sw_vers`, `uname -a`, `sysctl hw.memsize`, `sysctl vm.swapusage`, `vm_stat`, `memory_pressure`, selected read-only `vm.*` values, and three `vm_stat` captures separated by 2 seconds. Never use sudo or mutate preferences/sysctls.

- [ ] **Step 4: Verify source contract and commit**

```bash
/bin/sh scripts/tests/test_memory_vm_probe_source.sh
git add scripts/memory_vm_probe.sh scripts/tests/test_memory_vm_probe_source.sh docs/TESTING_CHECKLIST.md
git commit -m "test: add Catalina VM capability probe"
```

- [ ] **Step 5: HARD STOP for target-Mac evidence**

```bash
/bin/sh scripts/memory_vm_probe.sh \
  --output "$HOME/Desktop/catalina-10.15.7-memory-vm-probe.txt"
```

Do not continue to production classifier thresholds until the evidence review records which counters exist, their units, monotonic behavior, and observed idle/pressure ranges.

---

### Task 4: Freeze reviewed Catalina capabilities and static thresholds

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/CatalinaMemoryCapabilitiesTests.swift`
- Modify: `docs/TESTING_CHECKLIST.md`

**Interfaces:** Produces `CatalinaMemoryCapabilities.current` and `MemoryPressureThresholds.catalina10157`.

- [ ] **Step 1: Encode only evidence-approved capabilities**

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

- [ ] **Step 2: Test fixed percentage thresholds**

```swift
XCTAssertEqual(profile.availableModerateFraction, 0.15)
XCTAssertEqual(profile.availableStrongFraction, 0.08)
XCTAssertEqual(profile.availableSevereFraction, 0.05)
XCTAssertEqual(profile.compressedModerateFraction, 0.20)
XCTAssertEqual(profile.compressedStrongFraction, 0.30)
```

For each rate-based constant, add one assertion with the exact reviewed Catalina number from the probe-evidence review commit. The implementation task must not invent a number independently.

- [ ] **Step 3: Implement profile and verify**

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

### Task 5: Implement the multi-signal classifier and five-sample recovery hysteresis

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryPressureClassifier.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryPressureClassifierTests.swift`

**Interfaces:** Consumes `MemoryTelemetrySnapshot` + `MemoryPressureThresholds`; produces `MemoryPressureEvaluation`.

- [ ] **Step 1: Write failing tests**

Implement these exact test cases:

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

- [ ] **Step 2: Implement explicit evidence flags**

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

No intervention request before 3 High or 2 Critical consecutive candidates. Any Elevated/High/Critical sample resets the Healthy recovery counter.

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

**Interfaces:** Add `AppPriorityProcessResourceInspecting.residentBytes(pid:)`; produce `MemoryProcessFamilyCandidate` and deterministic ranked output.

- [ ] **Step 1: Add focused resource protocol**

```swift
public protocol AppPriorityProcessResourceInspecting {
    func residentBytes(pid: Int32) throws -> UInt64
}
```

Make `DarwinAppPriorityProcessInspector` conform by reusing `cp_read_process_resources`.

- [ ] **Step 2: Write family tests before implementation**

Cover same-user grouping, 3-sample background eligibility, frontmost exclusion, App Priority exclusion, root exclusion, protected exact-path exclusion, significance threshold, memory-growth tie-break, deterministic ordering, maximum three families, and recently-foregrounded penalty.

- [ ] **Step 3: Implement explicit protection policy**

Protect the approved critical names plus exact Catalina infrastructure paths. If frontmost application identity cannot be determined, refuse to admit new families.

- [ ] **Step 4: Implement deterministic ranking**

Rank by an explicit tuple of memory tier, growth tier, background sample count, then canonical family identifier. No randomization or opaque floating score.

- [ ] **Step 5: Run and commit**

```bash
swift test --filter MemoryProcessFamilyAnalyzerTests
git add app/CatalinaPerformance/Sources/CatalinaPerformancePriorityCore/AppPriorityProcessInspector.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryProcessFamilyAnalyzer.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryProcessFamilyAnalyzerTests.swift
git commit -m "feat: rank safe background memory families"
```

---

### Task 7: Add atomic recovery-state persistence before mutation

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementStateStore.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementStateStoreTests.swift`

**Interfaces:** `MemoryManagementStateStoring` with `loadActive`, `saveActive`, `complete`, `removeActiveIfResolved`.

- [ ] **Step 1: Write persistence tests**

Cover 0600 files, 0700 directory, temp+fsync+rename atomic write, symlink rejection, 1 MB limit, schema mismatch, corrupt active-state backup, unresolved state preventing deletion, and resolved state clearing active file.

- [ ] **Step 2: Implement versioned record**

```swift
public struct MemoryManagementSessionRecord: Codable, Equatable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let sessionIdentifier: String
    public let requestingUID: UInt32
    public let startedAt: Date
    public var managedFamilies: [MemoryManagedFamilyRecord]

    public var hasOutstandingRestoration: Bool {
        managedFamilies.contains { family in
            family.processes.contains { $0.requiresRestoration }
        }
    }
}
```

- [ ] **Step 3: Reuse the BackgroundServiceStateStore safety mechanics without sharing its schema/file**

State path: `~/Library/Application Support/CatalinaPerformance/memory_management/active-session.json`.

- [ ] **Step 4: Run and commit**

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
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift`

**Interfaces:** Consumes `AppPriorityProcessInspecting`, `AppPriorityPriorityMutating`, `MemoryManagementStateStoring`; produces `apply(families:)`, `restore(familyID:)`, `restoreAll()`, `recoverStaleState()`.

- [ ] **Step 1: Write mutation tests**

Verify: `0 -> +5 -> 0`, `+2 -> +5 -> +2`, existing `+8` unchanged, `-5 -> +5 -> -5`, PID/path/start-time mismatch refusal, save failure before write, restore-before-replacement, and partial failure retaining only unresolved obligations.

- [ ] **Step 2: Implement compare-and-verify writes**

```swift
let current = try inspector.process(pid: recorded.pid)
guard recorded.identity.matchesForMutation(current) else {
    throw MemoryInterventionError.identityMismatch
}
```

After each `setPriority`, read back with `priority(pid:)` and require the exact expected value.

- [ ] **Step 3: Enforce the three-family cap inside the controller**

Reject `apply(families:)` input above three even if the analyzer is wrong.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter MemoryInterventionControllerTests
git add app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryInterventionController.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift
git commit -m "feat: apply reversible memory scheduling policy"
```

---

### Task 9: Calibrate `taskpolicy` and gate I/O treatment

**Files:**
- Create: `scripts/memory_taskpolicy_calibration.sh`
- Create: `scripts/tests/test_memory_taskpolicy_calibration_source.sh`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryTaskPolicyAdapter.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/CatalinaMemoryCapabilities.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryInterventionControllerTests.swift`

**Interfaces:** Produces `MemoryIOPolicyApplying`.

- [ ] **Step 1: Write source contract**

Require a disposable child process. Reject arbitrary user PID arguments, permanent helpers, launchd writes, and unrelated process killing.

- [ ] **Step 2: Implement calibration sequence**

The script must launch its own disposable process, capture policy state, apply candidate background/I/O policy, verify it, restore the captured state, verify restoration, then terminate only that disposable child and write JSON evidence.

- [ ] **Step 3: HARD STOP for Catalina evidence**

If exact state capture or exact restoration cannot be proven, commit `taskPolicy: false`. Production then uses nice `+5` only.

- [ ] **Step 4: Implement adapter only for a passed calibration**

```swift
public protocol MemoryIOPolicyApplying {
    func capture(pid: Int32) throws -> MemoryIOPolicyState
    func applyBackground(pid: Int32) throws
    func restore(pid: Int32, original: MemoryIOPolicyState) throws
    func verify(pid: Int32, expected: MemoryIOPolicyState) throws -> Bool
}
```

When capability is false, return Unsupported without invoking `/usr/bin/taskpolicy`.

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

### Task 10: Integrate Memory Management with the existing 2-second session lifecycle

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementCoordinator.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/ProductionSessionMetricsCollector.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementCoordinatorTests.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionMetricIntegrationTests.swift`

**Interfaces:** `SessionMetricSnapshot.memoryManagement` is optional for backward-compatible decoding. `PerformanceSessionCoordinator` forwards completed samples to `MemoryManagementCoordinator.ingest`.

- [ ] **Step 1: Write coordinator tests**

Verify Healthy no-op, 3 High apply, 2 Critical apply without escalation, 5 Healthy restore, immediate foreground restore, immediate App Priority conflict restore, OFF/Emergency Restore immediate restore, insufficient telemetry stops new admission and restores conservatively, and Background Service recheck preserves `.resumedByUser`.

- [ ] **Step 2: Add optional memory snapshot with decoding default**

Old dashboard JSON without the new field must still decode.

- [ ] **Step 3: Inject `MemoryTelemetryCollecting?` into `SessionMetricsCollector`**

Capture memory telemetry in the same existing sampling call; no new timer.

- [ ] **Step 4: Implement coordinator ingestion off the main thread**

UI callbacks return to main only after immutable `MemoryManagementStatusSnapshot` creation.

- [ ] **Step 5: Add a narrow Background Service recheck callback**

It may ask the existing coordinator to rescan its approved catalog only; it cannot authorize new labels or reverse user resume decisions.

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

### Task 11: Add session aggregates and the dedicated Memory / Swap dashboard section

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionRecorder.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/MemorySessionDashboardPresentationTests.swift`
- Modify: `scripts/tests/test_session_dashboard_ui_source.sh`

**Interfaces:** Produces `MemorySessionAggregate` and `memoryRows` on `SessionDashboardViewModel`.

- [ ] **Step 1: Write presentation tests**

Active section must render State, Physical Used, Available, Compressed, Compression Growth, Swap Used, Swap Growth, Swap In, Swap Out, Page-Out Activity, Managed Workloads, and I/O Policy.

Completed report must retain baseline/max/peak/net growth/time-in-state/intervention-count/managed-family/restoration evidence from the spec.

- [ ] **Step 2: Add `MemorySessionAggregate`**

Store baseline and maximum state, baseline/peak compressed bytes, peak compression rate, baseline/peak/net swap, peak swap-in/out rate, seconds Healthy/Elevated/High/Critical, intervention episode count, managed-family names, and longest intervention duration.

- [ ] **Step 3: Add dedicated AppKit section**

Follow the existing Graphics / WindowServer section structure; do not dump these rows into the generic System list.

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

### Task 12: Wire ON/OFF, foreground protection, Advanced status, and Emergency Restore

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Modify: `app/CatalinaPerformance/Package.swift`
- Modify: `scripts/package_app.sh`
- Create: `scripts/tests/test_memory_management_ui_source.sh`
- Test: `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/MemoryManagementCoordinatorTests.swift`

**Interfaces:** Main app constructs one `MemoryManagementCoordinator`; Advanced receives immutable status only, with no tuning sliders.

- [ ] **Step 1: Add source-contract assertions before AppKit edits**

Require these strings:

```text
Memory Pressure Management
Automatically active with Performance Mode.
CPU deprioritization: nice +5
Maximum managed workloads: 3
```

Reject UI controls for nice level, family cap, swap target, or VM thresholds.

- [ ] **Step 2: Add production construction in `main.swift`**

Import `CatalinaPerformanceMemoryCore`. Use:

```swift
AdvancedPreferences.configDirectoryURL
    .appendingPathComponent("memory_management", isDirectory: true)
```

for recovery state.

- [ ] **Step 3: Integrate ON lifecycle**

Recover stale state before a new session. Permit new interventions only after Performance Mode is active and baseline/confirmation rules pass.

- [ ] **Step 4: Integrate OFF and Emergency Restore**

Call `restoreAll(reason:)` before final dashboard completion. If unresolved obligations remain, retain state and surface recovery-required status.

- [ ] **Step 5: Add foreground/App Priority conflict notifications**

Read AppKit frontmost identity on main, pass immutable identity to the coordinator, and restore a managed family before it can become an App Priority target.

- [ ] **Step 6: Replace the old Memory / Storage description**

Make Memory Pressure Management authoritative for memory status. Keep the manual storage report button as a separate disk-space diagnostic.

- [ ] **Step 7: Run and commit**

```bash
/bin/sh scripts/tests/test_memory_management_ui_source.sh
cd app/CatalinaPerformance
swift test --filter MemoryManagementCoordinatorTests
swift build --product CatalinaPerformance
cd ../..
git add app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift \
  app/CatalinaPerformance/Package.swift scripts/package_app.sh \
  scripts/tests/test_memory_management_ui_source.sh
git commit -m "feat: wire memory management into Performance Mode"
```

---

### Task 13: Full regression and Catalina runtime acceptance

**Files:**
- Modify: `docs/TESTING_CHECKLIST.md`
- Create: `docs/MEMORY_PRESSURE_RUNTIME_CHECKLIST.md`

**Interfaces:** Produces final evidence only; no new feature scope.

- [ ] **Step 1: Run source-safety checks**

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

- [ ] **Step 2: Run complete Catalina tests/builds**

```bash
cd app/CatalinaPerformance
rm -rf .build
swift test
swift build --product CatalinaPerformance
swift build --product CatalinaPerformancePriorityAgent
cd ../..
git diff --check
```

- [ ] **Step 3: Package and launch**

```bash
pkill -x CatalinaPerformance 2>/dev/null || true
rm -rf build
./scripts/package_app.sh
open ./build/CatalinaPerformance.app
```

- [ ] **Step 4: Validate no intervention under ordinary load**

Run Performance Mode for at least 2 minutes. Historical nonzero swap without active growth must not cause management; managed family count must remain zero when state is Healthy/Elevated.

- [ ] **Step 5: Validate controlled pressure lifecycle**

Confirm `Healthy -> Elevated -> High`, 3 High samples before mutation, at most 3 eligible families, verified nice `+5`, immediate restoration when a managed app becomes foreground, then exact restoration after 5 Healthy samples.

- [ ] **Step 6: Validate conflicts and recovery**

Confirm App Priority target exclusion, `.resumedByUser` preservation, OFF restore, Emergency Restore, PID-reuse refusal, and stale-session recovery.

- [ ] **Step 7: Compare repeated performance evidence**

Record swap growth, swap-out rate, compression growth, time High/Critical, UI responsiveness, and workload completion time. Do not claim benefit solely because intervention occurred.

- [ ] **Step 8: Document actual Catalina evidence and commit**

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
6. Foreground and App Priority conflicts restore before exclusion transitions complete.
7. Every mutation is preceded by atomic persisted recovery state.
8. Nice values restore exactly, including negative and nonzero originals.
9. `taskpolicy` remains disabled unless exact calibration succeeds.
10. OFF, Emergency Restore, failed activation, and stale-session recovery share restore-first logic.
11. Unavailable telemetry is never displayed or classified as zero.
12. Dashboard distinguishes high RAM usage from active pressure and historical swap from new swap growth.
13. No app termination, swap disabling, `purge`, VM/kernel mutation, arbitrary daemon unloading, or protected-service mutation exists.
14. Full Catalina tests/build/package pass and the real ON/OFF lifecycle is validated.
15. Any performance claim is supported by repeated before/after evidence.
