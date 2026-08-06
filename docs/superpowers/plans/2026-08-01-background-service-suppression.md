# Background Service Suppression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reversible Background Service Suppression subsystem that temporarily reduces unused Apple update, Photos, Mail, Messages/FaceTime, and Siri/speech activity during Performance Mode while protecting iCloud Keychain, Safari passwords, AirDrop, networking, diagnostics, and critical macOS services.

**Architecture:** Add a pure Swift `CatalinaPerformanceBackgroundServicesCore` target for policy, exact target identity, session state, worker suppression, dynamic resume, and recovery. Administrator-required Software Update and App Store preference changes remain in narrow reviewed shell scripts invoked by the existing privileged Performance Mode wrappers; user-owned worker discovery and verified `SIGTERM` suppression run off the AppKit main thread through the existing Catalina process-inspection boundary. The AppKit executable observes application activation, resumes a category for the rest of the current session, and publishes detailed state into the existing Session Dashboard.

**Tech Stack:** Swift 5.2, Swift Package Manager, Foundation, AppKit, XCTest, Darwin process APIs through `CatalinaPerformancePriorityCore`/`CatalinaProcessSupport`, POSIX shell, `launchctl`, `defaults`, `plutil`, macOS Catalina 10.15, Xcode 12.4.

## Global Constraints

- Automatic categories are macOS updates, App Store updates, Photos workers, Mail workers, Messages/FaceTime workers, and Siri/Dictation/speech workers.
- iCloud Drive suppression is opt-in, defaults OFF, and is disabled in the UI while Performance Mode is active.
- Opening an associated application or feature resumes that category for the remainder of the current Performance Mode session.
- Never intentionally stop or modify iCloud Keychain, Safari password/AutoFill synchronization, `securityd`, `trustd`, `accountsd`, shared CloudKit account services, push-notification infrastructure, AirDrop, networking, DNS, Finder, Dock, WindowServer, SystemUIServer, loginwindow, launchd, audio, accessibility, diagnostics, crash reporting, or root-owned processes not explicitly cataloged.
- No blanket `killall`, wildcard process matching, broad iCloud-disable command, launch-agent deletion, persistent `launchctl disable`, persistent unload, SIGKILL normal path, cache deletion, telemetry, SIP change, kext, SMC, MSR, undervolting, or fan control.
- A mutable worker requires an exact launch label, exact canonical executable path or finite allowed-path set, requesting-user UID, and revalidated PID/start identity immediately before mutation.
- No mutation occurs until original state is saved atomically and a known restore path exists.
- Category failures roll back only that category; shared-state, protected-service, or persistence failure aborts suppression before mutation but must not fail the existing core Performance Mode.
- OFF and Emergency Restore restore only changes CatalinaPerformance successfully made and preserve outstanding restoration records for retry.
- No synchronous process scanning, JSON I/O, script execution, or parsing on the AppKit main thread.
- Preserve the existing Foreground Session → UI responsiveness → privileged Performance sequence, App Priority behavior, dashboard behavior, and one-switch Performance Mode interface.
- Keep compatibility with macOS Catalina 10.15, Swift tools version 5.2, and Xcode 12.4.

---

## File Structure

### New Swift core target

- `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceModels.swift` — categories, policy states, target identities, worker records, session records, and dashboard-safe status values.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceStateStore.swift` — atomic versioned state persistence, permissions, corruption handling, and symlink rejection.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/CatalinaBackgroundServiceCatalog.swift` — exact Catalina-only target catalog and protected-service validation.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceWorkerController.swift` — exact process matching, verified termination, relaunch observation, and narrow restoration.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceSuppressionCoordinator.swift` — serialized lifecycle, monitor scheduling, dynamic resume, OFF, Emergency Restore, and stale recovery.
- `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceSettingsStatus.swift` — parser for the privileged settings scripts' status JSON.

### New AppKit integration

- `app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceActivityObserver.swift` — `NSWorkspace` application activation mapping and conservative feature-resume triggers.
- `app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceSuppressionPanelController.swift` — Advanced UI and iCloud Drive preference.

### New scripts

- `scripts/background_service_probe.sh` — read-only Catalina target and preference inventory.
- `scripts/lib/background_service_settings_common.sh` — strict state paths, plist-key capture/restore helpers, and safe output functions.
- `scripts/background_service_settings_apply.sh` — capture, temporarily disable, verify, and self-rollback Software Update/App Store settings.
- `scripts/background_service_settings_restore.sh` — exact settings restoration and verification.
- `scripts/background_service_settings_status.sh` — read-only status report for UI/dashboard diagnostics.

### Existing integration files

- `app/CatalinaPerformance/Package.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionRecorder.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSubsystemEvidence.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift`
- `app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift`
- `scripts/performance_on_with_priority.sh`
- `scripts/performance_off_with_priority.sh`
- `scripts/emergency_restore_with_priority.sh`
- `scripts/package_app.sh`
- `README.md`
- `docs/GUI_TESTING.md`
- `docs/KNOWN_ISSUES.md`
- `docs/TESTING_CHECKLIST.md`

### New tests

- `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceModelsTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceStateStoreTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/CatalinaBackgroundServiceCatalogTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceWorkerControllerTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceSuppressionCoordinatorTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceSettingsStatusTests.swift`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/BackgroundServiceDashboardTests.swift`
- `scripts/tests/test_background_service_probe.sh`
- `scripts/tests/test_background_service_settings.sh`
- `scripts/tests/test_background_service_wrappers.sh`
- `scripts/tests/test_background_service_ui_source.sh`
- `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/Fixtures/catalina-10.15.7-service-probe.txt`

---

### Task 1: Add the Background Services Module and Versioned Domain Model

**Files:**
- Modify: `app/CatalinaPerformance/Package.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceModels.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceModelsTests.swift`

**Interfaces:**
- Produces `BackgroundServiceCategory`, `BackgroundServiceCategoryState`, `BackgroundServiceTarget`, `BackgroundServiceWorkerRecord`, `BackgroundServiceCategoryRecord`, `BackgroundServiceSessionRecord`, and `BackgroundServiceStatusSnapshot`.
- Later tasks must use `BackgroundServiceSessionRecord.schemaVersion == 1` and never persist raw message, mail, photo, password, or account content.

- [ ] **Step 1: Add the new Swift target and test target**

Add to `Package.swift`:

```swift
.target(
    name: "CatalinaPerformanceBackgroundServicesCore",
    dependencies: ["CatalinaPerformancePriorityCore"]
),
.target(
    name: "CatalinaPerformance",
    dependencies: [
        "CatalinaPerformanceCore",
        "CatalinaPerformancePriorityCore",
        "CatalinaPerformanceDashboardCore",
        "CatalinaPerformanceBackgroundServicesCore"
    ]
),
.testTarget(
    name: "CatalinaPerformanceBackgroundServicesTests",
    dependencies: [
        "CatalinaPerformanceBackgroundServicesCore",
        "CatalinaPerformancePriorityCore"
    ]
)
```

- [ ] **Step 2: Write the failing model tests**

Create tests requiring these exact cases and Codable round trips:

```swift
import XCTest
@testable import CatalinaPerformanceBackgroundServicesCore

final class BackgroundServiceModelsTests: XCTestCase {
    func testAutomaticCategoriesAreStableAndICouldDriveIsOptional() {
        XCTAssertEqual(BackgroundServiceCategory.automatic, [
            .softwareUpdate, .appStoreUpdates, .photos, .mail,
            .messagesFaceTime, .siriSpeech
        ])
        XCTAssertFalse(BackgroundServiceCategory.automatic.contains(.iCloudDrive))
    }

    func testSessionRoundTripPreservesOutstandingRestoreState() throws {
        let record = BackgroundServiceSessionRecord.fixture(
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
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(BackgroundServiceSessionRecord.self, from: data), record)
        XCTAssertTrue(record.hasOutstandingRestoration)
    }
}
```

- [ ] **Step 3: Run the tests and verify RED**

Run:

```bash
cd app/CatalinaPerformance
swift test --filter BackgroundServiceModelsTests
```

Expected: compilation fails because the new target and model types do not exist.

- [ ] **Step 4: Implement the minimal public model API**

Use these exact declarations and explicit public initializers:

```swift
public enum BackgroundServiceCategory: String, Codable, CaseIterable {
    case softwareUpdate
    case appStoreUpdates
    case photos
    case mail
    case messagesFaceTime
    case siriSpeech
    case iCloudDrive

    public static let automatic: [BackgroundServiceCategory] = [
        .softwareUpdate, .appStoreUpdates, .photos, .mail,
        .messagesFaceTime, .siriSpeech
    ]
}

public enum BackgroundServiceCategoryState: String, Codable {
    case notConfigured, pending, unsupported, skipped
    case capturing, suppressing, paused, degraded
    case resumedByUser, restoring, restored, restoreFailed
}

public enum BackgroundServiceSuppressionMechanism: String, Codable {
    case settings
    case verifiedUserProcessTermination
}

public struct BackgroundServiceTarget: Codable, Equatable, Hashable {
    public let category: BackgroundServiceCategory
    public let launchLabel: String
    public let allowedExecutablePaths: [String]
    public let associatedBundleIdentifiers: [String]
    public let mechanism: BackgroundServiceSuppressionMechanism
    public init(category: BackgroundServiceCategory, launchLabel: String, allowedExecutablePaths: [String], associatedBundleIdentifiers: [String], mechanism: BackgroundServiceSuppressionMechanism) {
        self.category = category
        self.launchLabel = launchLabel
        self.allowedExecutablePaths = allowedExecutablePaths
        self.associatedBundleIdentifiers = associatedBundleIdentifiers
        self.mechanism = mechanism
    }
}
```

Implement immutable worker/category/session records with schema version, session UUID string, requesting UID, start date, exact original state, apply/verify/restore state, dynamic-resume reason, and computed `hasOutstandingRestoration`.

- [ ] **Step 5: Run GREEN and commit**

```bash
swift test --filter BackgroundServiceModelsTests
cd ../..
git add app/CatalinaPerformance/Package.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceModels.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceModelsTests.swift
git commit -m "feat: add background service suppression models"
```

---

### Task 2: Add Atomic Session Persistence and Recovery Semantics

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceStateStore.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceStateStoreTests.swift`

**Interfaces:**
- Produces `BackgroundServiceStateStoring`.
- Produces `BackgroundServiceStateStore(directoryURL:)` with `loadActive()`, `saveActive(_:)`, `complete(_:)`, and `removeActiveIfResolved()`.
- Active path is `~/Library/Application Support/CatalinaPerformance/background_service_suppression/active-session.json`.
- Completed path is `last-completed-session.json`.

- [ ] **Step 1: Write failing persistence tests**

Cover atomic replacement, directory mode `0700`, file mode `0600`, missing file, corrupt JSON backup, unsupported schema, symlink rejection, and preservation of unresolved restore work:

```swift
func testResolvedSessionCanBeRemovedButRestoreFailureCannot() throws {
    let store = try makeStore()
    try store.saveActive(.fixture(state: .restoreFailed))
    XCTAssertThrowsError(try store.removeActiveIfResolved())
    try store.saveActive(.fixture(state: .restored))
    XCTAssertNoThrow(try store.removeActiveIfResolved())
    XCTAssertNil(try store.loadActive())
}
```

- [ ] **Step 2: Verify RED**

```bash
cd app/CatalinaPerformance
swift test --filter BackgroundServiceStateStoreTests
```

Expected: compilation fails because `BackgroundServiceStateStore` does not exist.

- [ ] **Step 3: Implement the store**

Requirements:

- Create the directory with `FileManager.createDirectory` and POSIX permissions `0700`.
- Reject a directory or file whose resource values report `isSymbolicLink == true`.
- Encode to a same-directory temporary file, set mode `0600`, call `FileManager.replaceItemAt`, and never truncate the active file in place.
- Decode only schema version `1` and cap reads at `1 MiB`.
- Rename corrupt input to `active-session.corrupt-<unix timestamp>.json` before returning `.corruptState`.
- Keep only the newest corrupt backup.
- `complete(_:)` writes the completed record first, then removes active state only when no category is `.restoreFailed` or `.restoring`.

- [ ] **Step 4: Run GREEN and commit**

```bash
swift test --filter BackgroundServiceStateStoreTests
cd ../..
git add app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceStateStore.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceStateStoreTests.swift
git commit -m "feat: persist background service session state"
```

---

### Task 3: Add a Read-Only Catalina Probe and Build the Exact Target Catalog

**Files:**
- Create: `scripts/background_service_probe.sh`
- Create: `scripts/tests/test_background_service_probe.sh`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/Fixtures/catalina-10.15.7-service-probe.txt`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/CatalinaBackgroundServiceCatalog.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/CatalinaBackgroundServiceCatalogTests.swift`

**Interfaces:**
- Produces `CatalinaBackgroundServiceCatalog.current`.
- Produces `BackgroundServiceProtectedPolicy.validate(target:)`.
- The catalog contains only targets verified on the actual Catalina test Mac; a category without a reliable exact target is represented as unsupported, never guessed.

- [ ] **Step 1: Write the shell contract test first**

The test must assert the probe contains only read operations and rejects mutation tokens:

```sh
assert_contains 'launchctl print gui/' "$PROBE"
assert_contains 'ps -ww -axo' "$PROBE"
assert_contains 'defaults export' "$PROBE"
assert_not_contains 'killall' "$PROBE"
assert_not_contains 'launchctl disable' "$PROBE"
assert_not_contains 'launchctl bootout' "$PROBE"
assert_not_contains 'defaults write' "$PROBE"
assert_not_contains 'rm -f' "$PROBE"
```

- [ ] **Step 2: Implement the read-only probe**

`background_service_probe.sh` must:

- Require Darwin and a nonzero requesting UID.
- Print `sw_vers`, `uname -a`, and `sysctl -n hw.model`.
- Print `launchctl print gui/$UID`.
- Print `ps -ww -axo pid=,ppid=,uid=,lstart=,command=`.
- Export `/Library/Preferences/com.apple.SoftwareUpdate.plist` and the requesting user's `com.apple.commerce` preferences to stdout using `defaults export ... -` or print an explicit missing marker.
- Print only process/service metadata and preference keys/values; never inspect Mail, Messages, Photos, Safari, Keychain, or iCloud content.
- Accept `--uid <uid>` and `--output <path>`; output files use mode `0600`.

- [ ] **Step 3: Verify the probe test passes**

```bash
/bin/sh scripts/tests/test_background_service_probe.sh
```

Expected: `PASS: Background service probe source contract`.

- [ ] **Step 4: Capture the actual Catalina fixture before catalog mutation code is written**

On the user's Catalina Mac:

```bash
cd ~/Desktop/CatalinaPerformance
/bin/sh scripts/background_service_probe.sh \
  --uid "$(id -u)" \
  --output "$HOME/Desktop/catalina-10.15.7-service-probe.txt"
```

Copy the sanitized output verbatim to:

```text
app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/Fixtures/catalina-10.15.7-service-probe.txt
```

This checkpoint is mandatory. Do not add a mutable launch label or executable path based on memory, substring matching, or another macOS version.

- [ ] **Step 5: Write failing catalog safety tests**

Tests must require:

```swift
func testCatalogRejectsProtectedServicesAndWildcardPaths() throws {
    for target in CatalinaBackgroundServiceCatalog.current.targets {
        XCTAssertNoThrow(try BackgroundServiceProtectedPolicy.validate(target: target))
        XCTAssertFalse(target.launchLabel.contains("*"))
        XCTAssertFalse(target.allowedExecutablePaths.isEmpty)
        XCTAssertTrue(target.allowedExecutablePaths.allSatisfy { $0.hasPrefix("/") && !$0.contains("*") })
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
```

The protected set must include exact normalized names/labels for `securityd`, `trustd`, `accountsd`, `cloudd`, `apsd`, `sharingd`, `rapportd`, `mDNSResponder`, `configd`, `airportd`, `Finder`, `Dock`, `WindowServer`, `SystemUIServer`, `loginwindow`, `launchd`, `coreaudiod`, accessibility services, `diagnosticd`, `ReportCrash`, and `logd`.

- [ ] **Step 6: Implement the catalog from the captured fixture**

For each candidate worker found in the fixture:

1. Confirm its launch label appears in `launchctl print gui/$UID`.
2. Confirm every observed canonical executable path is finite and category-specific.
3. Confirm it is owned by the requesting user, not root.
4. Confirm its associated app bundle identifier can be observed for dynamic resume.
5. Add it only after the exact identity passes `BackgroundServiceProtectedPolicy`.
6. Put the category in `unsupportedCategories` when any requirement cannot be proven.

The production catalog must be a static immutable value; it must not derive mutation targets from live fuzzy process names.

- [ ] **Step 7: Run tests and commit**

```bash
cd app/CatalinaPerformance
swift test --filter CatalinaBackgroundServiceCatalogTests
cd ../..
git add scripts/background_service_probe.sh scripts/tests/test_background_service_probe.sh \
  app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/CatalinaBackgroundServiceCatalog.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/CatalinaBackgroundServiceCatalogTests.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/Fixtures/catalina-10.15.7-service-probe.txt
git commit -m "feat: add verified Catalina background service catalog"
```

---

### Task 4: Add Exact Software Update and App Store Settings Capture/Restore

**Files:**
- Create: `scripts/lib/background_service_settings_common.sh`
- Create: `scripts/background_service_settings_apply.sh`
- Create: `scripts/background_service_settings_restore.sh`
- Create: `scripts/background_service_settings_status.sh`
- Create: `scripts/tests/test_background_service_settings.sh`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceSettingsStatus.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceSettingsStatusTests.swift`

**Interfaces:**
- Scripts read `CATALINA_PERFORMANCE_STATE_DIR` and `--requesting-uid`.
- State directory: `$CATALINA_PERFORMANCE_STATE_DIR/background_service_suppression/settings`.
- Status file: `settings-status.json`.
- Exit `0`: applied/restored and verified; `10`: nothing supported/configured; `20`: apply failed but self-rollback verified; `21`: restoration incomplete; `2`: usage error.
- Produces Swift `BackgroundServiceSettingsStatus.load(from:)`.

- [ ] **Step 1: Write failing stubbed shell tests**

Create fake `defaults`, `plutil`, and `stat` commands in a temporary PATH. Tests must prove:

- Each key's original presence and value are captured before any write.
- Missing keys remain missing after restore.
- Existing boolean/integer/string values restore exactly.
- A failed second write triggers restoration of the first write.
- Unknown keys and unknown preference domains are rejected.
- No protected domain is writable.
- Status JSON distinguishes `paused`, `unsupported`, `rolledBack`, `restored`, and `restoreFailed`.

- [ ] **Step 2: Verify RED**

```bash
/bin/sh scripts/tests/test_background_service_settings.sh
```

Expected: failure because the settings scripts do not exist.

- [ ] **Step 3: Implement strict common helpers**

`background_service_settings_common.sh` must expose only:

```sh
capture_preference_key DOMAIN KEY OUTPUT_FILE
write_boolean_preference DOMAIN KEY VALUE
restore_preference_key DOMAIN KEY SNAPSHOT_FILE
verify_boolean_preference DOMAIN KEY EXPECTED
write_settings_status STATE NOTE
```

Hard-code the finite supported domain/key pairs proven by the Task 3 probe. Do not accept a domain or key from untrusted arbitrary input. Store one JSON snapshot per key with:

```json
{"domain":"...","key":"...","wasPresent":true,"type":"bool","value":true}
```

- [ ] **Step 4: Implement apply, restore, and status scripts**

`background_service_settings_apply.sh` sequence:

1. Validate root/admin execution and requesting UID.
2. Refuse to overwrite an unresolved baseline.
3. Capture every supported Software Update/App Store key.
4. Write the disabled values.
5. Verify all writes.
6. On any failure, restore every changed key in reverse order and report exit `20` or `21`.
7. Write `settings-status.json` atomically.

`background_service_settings_restore.sh` restores from snapshots, verifies exact values/presence, removes only resolved snapshot files, and leaves failures for retry.

- [ ] **Step 5: Add the Swift status parser tests and implementation**

Use explicit types:

```swift
public struct BackgroundServiceSettingsCategoryStatus: Codable, Equatable {
    public let category: BackgroundServiceCategory
    public let state: BackgroundServiceCategoryState
    public let note: String?
    public init(category: BackgroundServiceCategory, state: BackgroundServiceCategoryState, note: String?) {
        self.category = category
        self.state = state
        self.note = note
    }
}
```

Reject files larger than `256 KiB`, unsupported schema versions, symlinks, and unknown category strings.

- [ ] **Step 6: Run GREEN and commit**

```bash
/bin/sh scripts/tests/test_background_service_settings.sh
cd app/CatalinaPerformance
swift test --filter BackgroundServiceSettingsStatusTests
cd ../..
git add scripts/lib/background_service_settings_common.sh \
  scripts/background_service_settings_apply.sh \
  scripts/background_service_settings_restore.sh \
  scripts/background_service_settings_status.sh \
  scripts/tests/test_background_service_settings.sh \
  app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceSettingsStatus.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceSettingsStatusTests.swift
git commit -m "feat: manage update settings reversibly"
```

---

### Task 5: Add Verified User-Worker Suppression and Narrow Restoration

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceWorkerController.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceWorkerControllerTests.swift`

**Interfaces:**
- Consumes `AppPriorityProcessInspecting` and exact `BackgroundServiceTarget` values.
- Produces `BackgroundServiceWorkerControlling`.
- Produces methods:
  - `capture(category:uid:) throws -> [BackgroundServiceWorkerRecord]`
  - `suppress(category:records:uid:) -> BackgroundServiceCategoryRecord`
  - `verifySuppressed(category:records:uid:) -> BackgroundServiceCategoryRecord`
  - `restore(category:records:uid:) -> BackgroundServiceCategoryRecord`

- [ ] **Step 1: Write failing controller tests**

Required cases:

```swift
func testSuppressionRevalidatesIdentityImmediatelyBeforeSIGTERM() throws {
    let inspector = MutableFakeProcessInspector(initial: [matchingProcess])
    let mutator = RecordingSignalMutator()
    let controller = makeController(inspector: inspector, mutator: mutator)
    let captured = try controller.capture(category: .photos, uid: 501)
    inspector.replace(pid: matchingProcess.pid, with: reusedPIDProcess)
    let result = controller.suppress(category: .photos, records: captured, uid: 501)
    XCTAssertTrue(mutator.signals.isEmpty)
    XCTAssertEqual(result.state, .degraded)
}
```

Also test root-owned rejection, protected path rejection, noncatalog path rejection, exact-path success, originally-not-running behavior, process already exited, SIGTERM failure, and restoration only for workers originally running and successfully stopped.

- [ ] **Step 2: Verify RED**

```bash
cd app/CatalinaPerformance
swift test --filter BackgroundServiceWorkerControllerTests
```

- [ ] **Step 3: Implement protocols and Darwin adapters**

```swift
public protocol BackgroundServiceSignalMutating {
    func terminate(pid: Int32) throws
}

public protocol BackgroundServiceLaunchctlRestoring {
    func kickstart(label: String, uid: UInt32) throws
}
```

`DarwinBackgroundServiceSignalMutator` uses `Darwin.kill(pid, SIGTERM)` only. `DarwinBackgroundServiceLaunchctlRestorer` runs exactly:

```text
/bin/launchctl kickstart gui/<uid>/<catalog launch label>
```

It accepts only an already validated catalog target; it exposes no arbitrary command or label API to AppKit.

- [ ] **Step 4: Implement capture/suppress/restore rules**

- Match only requesting-user processes whose canonical executable path is one of the target's finite allowed paths.
- Save PID, PPID, UID, canonical path, start seconds/microseconds, launch label, original running state, stop attempt, and restore attempt.
- Re-read the process immediately before `SIGTERM`; require `matchesForMutation`.
- Wait up to `3.0` seconds for exit using `0.1`-second polling off the main thread.
- Restoration uses `launchctl kickstart` only when the worker was running before suppression, CatalinaPerformance confirmed it stopped, the category was not resumed by user, and no matching worker is already running.
- Verify restored presence by exact path and UID, not process name.

- [ ] **Step 5: Run GREEN and commit**

```bash
swift test --filter BackgroundServiceWorkerControllerTests
cd ../..
git add app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceWorkerController.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceWorkerControllerTests.swift
git commit -m "feat: suppress verified user background workers"
```

---

### Task 6: Add the Serialized Suppression Coordinator and Dynamic Resume State

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceSuppressionCoordinator.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceSuppressionCoordinatorTests.swift`

**Interfaces:**
- Produces `BackgroundServiceSuppressionCoordinating`.
- Public methods:
  - `prepareForPerformanceOn(iCloudDriveEnabled:completion:)`
  - `performanceOnSucceeded(completion:)`
  - `performanceOnFailed(completion:)`
  - `resume(category:reason:)`
  - `prepareForPerformanceOff(completion:)`
  - `performanceOffFinished(settingsStatus:completion:)`
  - `recoverStaleSession(completion:)`
  - `currentSnapshot(completion:)`
- Publishes `onStatusChange: ((BackgroundServiceStatusSnapshot) -> Void)?` on the configured callback queue.

- [ ] **Step 1: Write failing lifecycle tests**

Cover:

- Original baseline is captured once and not overwritten by repeated ON.
- Monitor scans at most one cycle at a time every `5.0` seconds.
- A worker that relaunches is re-suppressed while eligible.
- `resume(category:)` permanently exempts the category for that session.
- A resumed category is never re-suppressed in later scans.
- One category failure does not stop other categories.
- Persistence/protected-policy failure prevents all worker mutation.
- OFF stops monitoring before restoration.
- Stale recovery retries only unresolved work.

Use a manual scheduler rather than real time:

```swift
let scheduler = ManualBackgroundServiceScheduler()
coordinator.performanceOnSucceeded { _ in }
scheduler.fire()
scheduler.fire()
XCTAssertEqual(workerController.suppressCalls.count, 1)
```

- [ ] **Step 2: Verify RED**

```bash
cd app/CatalinaPerformance
swift test --filter BackgroundServiceSuppressionCoordinatorTests
```

- [ ] **Step 3: Implement a single-queue coordinator**

- Use a private serial `DispatchQueue(label:qos:)`.
- Never call worker inspection, state store, or settings parser on `.main`.
- `prepareForPerformanceOn` creates the active record with automatic categories plus iCloud Drive only when enabled; capture exact worker baseline and persist it without mutation.
- `performanceOnSucceeded` reads settings status, suppresses eligible user workers, persists each category result, starts monitoring, and returns degraded status without failing Performance Mode.
- `performanceOnFailed` restores any user-worker changes and leaves root-settings cleanup to the settings script's self-rollback status.
- Monitoring skips a tick when the previous scan is still running.
- `resume(category:reason:)` marks the category `.resumedByUser`, ceases re-suppression, and does not force-launch workers; normal app demand or OFF restoration handles relaunch.
- `prepareForPerformanceOff` cancels monitoring and returns a snapshot before privileged restore begins.
- `performanceOffFinished` combines settings-script outcomes with worker restoration, completes state only when resolved, and leaves `.restoreFailed` records active.

- [ ] **Step 4: Run GREEN and commit**

```bash
swift test --filter BackgroundServiceSuppressionCoordinatorTests
cd ../..
git add app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceSuppressionCoordinator.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceBackgroundServicesTests/BackgroundServiceSuppressionCoordinatorTests.swift
git commit -m "feat: coordinate background service suppression sessions"
```

---

### Task 7: Add AppKit Activity Observation and Session-Long Resume

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceActivityObserver.swift`
- Create: `scripts/tests/test_background_service_ui_source.sh`

**Interfaces:**
- Consumes `BackgroundServiceSuppressionCoordinating.resume(category:reason:)`.
- Produces `BackgroundServiceActivityObserving.start()` and `.stop()`.
- Uses exact bundle identifiers from the verified catalog; no display-name or substring matching.

- [ ] **Step 1: Write the source-contract test**

Require:

```sh
assert_contains 'NSWorkspace.didLaunchApplicationNotification' "$SOURCE"
assert_contains 'NSWorkspace.didActivateApplicationNotification' "$SOURCE"
assert_not_contains 'localizedCaseInsensitiveContains' "$SOURCE"
assert_not_contains 'contains("Photos")' "$SOURCE"
assert_not_contains 'killall' "$SOURCE"
```

- [ ] **Step 2: Implement the observer**

- Subscribe to `NSWorkspace.shared.notificationCenter` launch and activation notifications.
- Resolve only `NSRunningApplication.bundleIdentifier`.
- Map exact identifiers supplied by `CatalinaBackgroundServiceCatalog` to `.photos`, `.mail`, `.messagesFaceTime`, `.appStoreUpdates`, and `.softwareUpdate`.
- For Siri/Dictation/speech, include only an exact activation trigger proven by the Task 3 probe. When no reliable trigger exists, the catalog must mark `.siriSpeech` unsupported rather than suppressing it without a resume path.
- On first trigger, call `resume(category:reason:)` with copy such as `User opened Mail.`.
- Deduplicate repeated launch/activation notifications.
- Remove observers in `stop()` and `deinit`.

- [ ] **Step 3: Run the contract test and commit**

```bash
/bin/sh scripts/tests/test_background_service_ui_source.sh
git add app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceActivityObserver.swift \
  scripts/tests/test_background_service_ui_source.sh
git commit -m "feat: resume service categories on user activity"
```

---

### Task 8: Integrate Administrator Settings into Existing Performance Wrappers

**Files:**
- Modify: `scripts/performance_on_with_priority.sh`
- Modify: `scripts/performance_off_with_priority.sh`
- Modify: `scripts/emergency_restore_with_priority.sh`
- Create: `scripts/lib/background_service_wrapper_common.sh`
- Create: `scripts/tests/test_background_service_wrappers.sh`

**Interfaces:**
- Existing administrator prompt remains the only prompt.
- Wrappers export `CATALINA_PERFORMANCE_BACKGROUND_SERVICE_STATE_DIR` beneath the existing state directory.
- Background suppression failure degrades its subsystem but does not undo a successful core Performance Mode unless the settings script reports unresolved partial mutation.

- [ ] **Step 1: Write failing wrapper tests with stubs**

Test these exact sequences:

**ON success:**

```text
priority validate
performance_on.sh
background_service_settings_apply.sh
priority start
```

**ON background settings exit 20:** core remains ON, priority may start, wrapper exits `0`, status records rolled back/degraded.

**ON background settings exit 21:** wrapper attempts `background_service_settings_restore.sh`; if unresolved, wrapper exits `1` and runs `performance_off.sh --force` so no partially restored settings are hidden.

**OFF:** stop/restore priority, restore background settings, then run `performance_off.sh`; all are attempted even after one failure.

**Emergency:** stop/restore priority, restore background settings, then run `emergency_restore.sh`; all are attempted.

- [ ] **Step 2: Verify RED**

```bash
/bin/sh scripts/tests/test_background_service_wrappers.sh
```

- [ ] **Step 3: Implement finite wrapper helpers and integration**

`background_service_wrapper_common.sh` provides only:

```sh
run_background_settings_apply
run_background_settings_restore
background_settings_status_file
```

Do not add a generic arbitrary-script runner. Pass `--requesting-uid "$REQUESTING_UID"` to every settings script.

- [ ] **Step 4: Run GREEN and regression wrapper tests**

```bash
/bin/sh scripts/tests/test_background_service_wrappers.sh
/bin/sh scripts/tests/test_app_priority_wrappers.sh
```

- [ ] **Step 5: Commit**

```bash
git add scripts/performance_on_with_priority.sh \
  scripts/performance_off_with_priority.sh \
  scripts/emergency_restore_with_priority.sh \
  scripts/lib/background_service_wrapper_common.sh \
  scripts/tests/test_background_service_wrappers.sh
git commit -m "feat: integrate background settings with performance mode"
```

---

### Task 9: Add Advanced Preferences and Background Service UI

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceSuppressionPanelController.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Modify: `scripts/tests/test_background_service_ui_source.sh`

**Interfaces:**
- Adds UserDefaults key `advanced.pauseICloudDriveWhileOn`, default `false`.
- Adds environment/config value `PAUSE_ICLOUD_DRIVE_WHILE_ON=0|1`.
- The panel consumes `BackgroundServiceStatusSnapshot` and exposes `setInteractionState(actionsEnabled:performanceModeIsOn:)`.

- [ ] **Step 1: Extend the source-contract test before UI code**

Require copy and behavior:

```text
Background Service Suppression
Automatic while Performance Mode is ON
macOS automatic updates
App Store background updates
Photos background workers
Mail background workers
Messages and FaceTime workers
Siri, Dictation, and speech workers
Pause iCloud Drive synchronization while Performance Mode is ON
Protected: iCloud Keychain, Safari passwords, AirDrop, networking, diagnostics, crash reporting, and essential macOS services
```

Require the iCloud checkbox to be disabled while Performance Mode is ON.

- [ ] **Step 2: Add preference persistence**

In `AdvancedPreferences`:

```swift
static let pauseICloudDriveKey = "advanced.pauseICloudDriveWhileOn"
```

Register it as `false`, write `PAUSE_ICLOUD_DRIVE_WHILE_ON`, and keep the existing strict known-key script parser updated.

- [ ] **Step 3: Implement the panel controller**

Use static explanatory rows for automatic categories, one checkbox for iCloud Drive, status text, and a wrapped protected-services explanation. Do not add per-category automatic toggles in this revision.

- [ ] **Step 4: Insert the panel into the existing scrollable Advanced stack**

Place it after the current Background Services section and before Power Behavior. Preserve the existing `FlippedDocumentView` sizing and `updateAdvancedDocumentSize()` flow.

- [ ] **Step 5: Run source/layout tests and commit**

```bash
/bin/sh scripts/tests/test_background_service_ui_source.sh
/bin/sh scripts/tests/test_advanced_layout_source.sh
git add app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceSuppressionPanelController.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift \
  scripts/tests/test_background_service_ui_source.sh
git commit -m "feat: add background suppression advanced controls"
```

---

### Task 10: Connect the Coordinator to ON, OFF, Emergency Restore, and Startup Recovery

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceActivityObserver.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceSuppressionPanelController.swift`
- Modify: `scripts/tests/test_background_service_ui_source.sh`

**Interfaces:**
- `MainWindowController` owns one suppression coordinator and one activity observer.
- Dashboard finalization waits for background worker restoration completion, but background collection/restoration errors do not block core OFF/Emergency scripts.

- [ ] **Step 1: Add failing source assertions for lifecycle hooks**

Require calls at these exact points:

- Before existing ON sequence: `prepareForPerformanceOn`.
- After ON sequence success: `performanceOnSucceeded` and observer `start()`.
- After ON sequence failure: `performanceOnFailed`.
- Before OFF/Emergency scripts: `prepareForPerformanceOff` and observer `stop()`.
- After scripts finish: `performanceOffFinished` before `performanceSessionCoordinator.finalizationCompleted`.
- At app launch: `recoverStaleSession`.

- [ ] **Step 2: Add the background state directory and settings status paths**

Use:

```swift
let directory = AdvancedPreferences.configDirectoryURL
    .appendingPathComponent("background_service_suppression", isDirectory: true)
```

Pass the system settings status URL under `AdvancedPreferences.systemStateDirectoryURL/background_service_suppression/settings/settings-status.json`.

- [ ] **Step 3: Integrate ON without changing the existing script order**

Flow:

1. `prepareForPerformanceOn(iCloudDriveEnabled:)`.
2. Existing dashboard baseline preparation.
3. Existing Foreground/UI/Performance sequence.
4. When sequence succeeds, call `performanceOnSucceeded`, start activity observer, then call dashboard `onSequenceCompleted(succeeded: true)`.
5. When sequence fails, call `performanceOnFailed`, then dashboard failure completion.

Suppression degradation updates status text/output but does not convert a successful core ON into failure.

- [ ] **Step 4: Integrate OFF and Emergency Restore**

Stop monitoring before scripts. After scripts complete, parse settings status, restore worker state, then pass combined command evidence to the dashboard. Keep unresolved suppression restoration visible even when Performance Mode's main marker is OFF.

- [ ] **Step 5: Add startup recovery messaging**

At launch, call `recoverStaleSession`. When root settings remain unresolved, do not show an automatic administrator prompt; show `Recovery required` and route the existing Emergency Restore button through the recorded state. User-level worker restoration may run automatically off the main thread.

- [ ] **Step 6: Run tests and commit**

```bash
/bin/sh scripts/tests/test_background_service_ui_source.sh
cd app/CatalinaPerformance
swift test --filter BackgroundServiceSuppressionCoordinatorTests
cd ../..
git add app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceActivityObserver.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceSuppressionPanelController.swift \
  scripts/tests/test_background_service_ui_source.sh
git commit -m "feat: integrate background suppression lifecycle"
```

---

### Task 11: Add Per-Category Session Dashboard Reporting

**Files:**
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionRecorder.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSubsystemEvidence.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/BackgroundServiceDashboardTests.swift`
- Modify: `scripts/tests/test_session_dashboard_ui_source.sh`

**Interfaces:**
- Adds `PerformanceSubsystem.backgroundServiceSuppression`.
- Adds optional `[BackgroundServiceDashboardCategoryStatus]` to active/completed session records for backward-compatible decoding.
- Adds `PerformanceSessionCoordinator.replaceBackgroundServiceStatuses(_:)`.

- [ ] **Step 1: Write failing dashboard model/presentation tests**

Require exact display states:

```text
Not configured
Unsupported
Skipped
Paused
Resumed — user opened Photos
Restored
Restore failed
```

Require separate rows for:

```text
macOS Updates
App Store Updates
Photos Workers
Mail Workers
Messages / FaceTime Workers
Siri / Speech Workers
iCloud Drive
```

Missing evidence must render `Unknown`, not `Restored`.

- [ ] **Step 2: Verify RED**

```bash
cd app/CatalinaPerformance
swift test --filter BackgroundServiceDashboardTests
```

- [ ] **Step 3: Extend persisted session models compatibly**

Define a dashboard-local Codable value rather than importing AppKit:

```swift
public struct BackgroundServiceDashboardCategoryStatus: Codable, Equatable {
    public let categoryRawValue: String
    public let stateRawValue: String
    public let note: String?
    public let updatedAt: Date
    public init(categoryRawValue: String, stateRawValue: String, note: String?, updatedAt: Date) {
        self.categoryRawValue = categoryRawValue
        self.stateRawValue = stateRawValue
        self.note = note
        self.updatedAt = updatedAt
    }
}
```

Add it as an optional property so reports written before this feature still decode.

- [ ] **Step 4: Add recorder/coordinator replacement API**

`replaceBackgroundServiceStatuses(_:)` updates the active record, persists it, and publishes a fresh view model on the dashboard queue. It must not alter metric aggregates.

- [ ] **Step 5: Add presentation rows and subsystem summary**

Map the six automatic categories plus iCloud Drive to the exact labels above. The aggregate subsystem row is:

- `Not configured` when every category is not configured.
- `Applied` when all requested supported categories are paused or resumed by user.
- `Partially applied` when any requested category is unsupported/skipped/degraded.
- `Restored` only when every changed category is verified restored or had already resumed by user with no remaining setting difference.
- `Partially restored` when any outstanding restoration remains.

- [ ] **Step 6: Wire coordinator snapshots into the dashboard**

In `MainWindowController`, set suppression coordinator `onStatusChange` to convert and call `performanceSessionCoordinator.replaceBackgroundServiceStatuses` on the main callback queue.

- [ ] **Step 7: Run GREEN and commit**

```bash
swift test --filter BackgroundServiceDashboardTests
cd ../..
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
git add app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore \
  app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift \
  app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift \
  app/CatalinaPerformance/Tests/CatalinaPerformanceDashboardTests/BackgroundServiceDashboardTests.swift \
  scripts/tests/test_session_dashboard_ui_source.sh
git commit -m "feat: report background suppression in dashboard"
```

---

### Task 12: Package Scripts, Document Safety, and Add Full Source Contracts

**Files:**
- Modify: `scripts/package_app.sh`
- Modify: `README.md`
- Modify: `docs/GUI_TESTING.md`
- Modify: `docs/KNOWN_ISSUES.md`
- Modify: `docs/TESTING_CHECKLIST.md`
- Modify: `scripts/tests/test_background_service_settings.sh`
- Modify: `scripts/tests/test_background_service_wrappers.sh`
- Modify: `scripts/tests/test_background_service_ui_source.sh`

**Interfaces:**
- Packaged app includes every new script under `Contents/Resources/scripts` with executable permissions.
- Documentation makes no unconditional performance claim.

- [ ] **Step 1: Add packaging assertions before modifying packaging**

Require the package script to copy:

```text
background_service_probe.sh
background_service_settings_apply.sh
background_service_settings_restore.sh
background_service_settings_status.sh
lib/background_service_settings_common.sh
lib/background_service_wrapper_common.sh
```

- [ ] **Step 2: Update packaging and run package source checks**

Keep the priority agent packaging unchanged. Ensure all new scripts are executable and no state fixture/probe output is packaged.

- [ ] **Step 3: Update documentation**

Document:

- Automatic and optional categories.
- Dynamic resume for the current session.
- Protected services.
- Unsupported-category behavior.
- Exact OFF/Emergency restoration and stale recovery.
- The possibility that measured benefit is small when services are already idle.
- The requirement to validate Keychain, Safari passwords, AirDrop, networking, push notifications, diagnostics, and crash reporting on Catalina.

- [ ] **Step 4: Add prohibited-operation scans**

Source-contract tests must fail on mutable code containing:

```text
killall
SIGKILL
launchctl disable
launchctl bootout
rm ... LaunchAgents
securityd
trustd
accountsd
cloudd
apsd
sharingd
mDNSResponder
diagnosticd
ReportCrash
```

Protected names may appear only in protected-policy lists, documentation, and tests asserting they are excluded. The scan must distinguish those paths from mutation catalogs/scripts.

- [ ] **Step 5: Run documentation/source contracts and commit**

```bash
/bin/sh scripts/tests/test_background_service_probe.sh
/bin/sh scripts/tests/test_background_service_settings.sh
/bin/sh scripts/tests/test_background_service_wrappers.sh
/bin/sh scripts/tests/test_background_service_ui_source.sh
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
/bin/sh scripts/tests/test_advanced_layout_source.sh
git diff --check
git add scripts/package_app.sh README.md docs scripts/tests
git commit -m "docs: document background service suppression safety"
```

---

### Task 13: Full Regression, Catalina Integration, and Measured Acceptance

**Files:**
- Modify only when a test exposes a defect.
- Update: `docs/TESTING_CHECKLIST.md` with actual Catalina results.

**Interfaces:**
- Produces final verified patch/branch with no uncommitted generated build artifacts.

- [ ] **Step 1: Run the complete automated suite from a clean build**

```bash
cd ~/Desktop/CatalinaPerformance

/bin/sh scripts/tests/test_foreground_session.sh all
/bin/sh scripts/tests/test_advanced_layout_source.sh
/bin/sh scripts/tests/test_app_priority_wrappers.sh
/bin/sh scripts/tests/test_app_priority_ui_source.sh
/bin/sh scripts/tests/test_catalina_process_support_source.sh
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
/bin/sh scripts/tests/test_background_service_probe.sh
/bin/sh scripts/tests/test_background_service_settings.sh
/bin/sh scripts/tests/test_background_service_wrappers.sh
/bin/sh scripts/tests/test_background_service_ui_source.sh

cd app/CatalinaPerformance
rm -rf .build
swift test
swift build --product CatalinaPerformance
swift build --product CatalinaPerformancePriorityAgent
cd ../..

git diff --check
```

Expected: every shell/source test passes, all Swift tests pass with `0 failures`, both products build, and `git diff --check` prints nothing.

- [ ] **Step 2: Package a fresh app**

```bash
pkill -x CatalinaPerformance 2>/dev/null || true
rm -rf build
./scripts/package_app.sh
open ./build/CatalinaPerformance.app
```

- [ ] **Step 3: Verify each supported category on actual Catalina**

For each category separately:

1. Capture baseline settings/processes.
2. Turn Performance Mode ON.
3. Confirm only exact catalog targets stop or settings change.
4. Confirm dashboard status.
5. Open the associated app/feature.
6. Confirm the category changes to `Resumed — user opened ...` and remains exempt.
7. Turn Performance Mode OFF.
8. Confirm exact setting restoration and originally-running worker restoration.
9. Repeat ON/OFF once to prove idempotency.

- [ ] **Step 4: Verify protected functionality during active suppression**

Manually verify:

- Safari can retrieve and autofill an iCloud Keychain password.
- Keychain Access opens and reads existing items.
- AirDrop remains discoverable and can transfer a small file.
- Wi-Fi, DNS, and ordinary browsing work.
- A normal push notification can arrive.
- Diagnostics/crash-report processes remain untouched in process comparisons.
- Finder, Dock, WindowServer, audio, and accessibility behavior remain normal.

Any failure blocks release and requires removing the overlapping target from the catalog.

- [ ] **Step 5: Verify crash and stale-session recovery**

1. Turn Performance Mode ON.
2. Force-quit CatalinaPerformance without turning mode OFF.
3. Reopen it.
4. Confirm user-owned worker recovery runs and root-setting recovery is reported without an automatic password prompt.
5. Run Emergency Restore.
6. Confirm the active session file is removed only after every restoration verifies.

- [ ] **Step 6: Compare measurable effect without claiming causality**

Run alternating five-minute idle/normal-browsing sessions:

```text
OFF → ON → ON → OFF → OFF → ON
```

Record Session Dashboard system CPU, memory used, swap, and duration plus visible responsiveness. Report the feature as useful only if it reduces actual background load without degrading interactive behavior. A neutral or mixed result remains valid; do not alter safety boundaries to chase a benchmark.

- [ ] **Step 7: Final repository checks and milestone commit**

```bash
git status --short
git diff --stat
git diff --check

git add .
git commit -m "feat: add reversible background service suppression"
```

Do not commit `build/`, `.build/`, captured Desktop diagnostics, unsanitized probe output, or Application Support state.
