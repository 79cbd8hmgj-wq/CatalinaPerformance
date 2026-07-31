# Foreground Performance Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Foreground Performance Session that gracefully closes explicitly selected GUI applications, applies reversible UI-responsiveness preferences, integrates with Performance Mode ON/OFF, and restores only state that CatalinaPerformance actually changed.

**Architecture:** Keep the existing AppKit/script boundary. POSIX shell scripts own application-session and UI-preference state transitions under the current user's Application Support directory; AppKit lists eligible applications, persists selections, sequences scripts through the existing global action lock, and displays results. Introduce small pure Swift models and a sequence coordinator so filtering, preference serialization, and rollback ordering can be unit tested without launching the GUI.

**Tech Stack:** macOS Catalina 10.15, Swift 5.2/AppKit, Swift Package Manager, POSIX `sh`, `/usr/bin/osascript`, `/usr/bin/defaults`, `/usr/bin/open`, XCTest, local-development `.app` packaging.

## Global Constraints

- Target macOS Catalina 10.15 and Xcode 12.4.
- Keep the feature disabled by default and require explicit application selection.
- Identify applications by bundle identifier, never by saved PID.
- Permanently exclude CatalinaPerformance, Terminal, iTerm/iTerm2, Finder, Dock, SystemUIServer, WindowServer, and loginwindow.
- Do not use force quit, `kill`, `killall`, Unix signals, process suspension, or process-priority changes.
- Do not use sudo in foreground-session or UI-responsiveness scripts.
- Do not add fan/SMC control, SIP changes, Turbo Boost control, undervolting, MSR access, kext loading, launch-daemon manipulation, cache deletion, or CPU power-limit changes.
- Write recoverable runtime state before requesting any application quit or changing any preference.
- Preserve failed restore state for retry.
- Existing Performance ON/OFF and Emergency Restore behavior must remain independently usable.
- Shell code must remain POSIX-compatible `sh`; never `eval` preferences or runtime state.
- All GUI script actions must respect the existing single-action lock and re-enable controls on success, failure, cancellation, timeout, and rollback paths.

---

## File Map

### New shell files

- `scripts/lib/foreground_session_common.sh` — validated paths, known preference parsing, bundle-ID validation/exclusions, safe TSV helpers, and command indirection for tests.
- `scripts/foreground_session_list.sh` — read-only eligible-app listing.
- `scripts/foreground_session_apply.sh` — graceful quit requests and confirmed-close state.
- `scripts/foreground_session_restore.sh` — selective relaunch and retryable restore state.
- `scripts/foreground_session_state.sh` — read-only state and summary reporting.
- `scripts/ui_responsiveness_apply.sh` — exact pre-state capture and temporary animation preferences.
- `scripts/ui_responsiveness_restore.sh` — exact value/absence restoration.
- `scripts/tests/test_foreground_session.sh` — portable shell tests with fake `osascript`, `defaults`, and `open` commands.

### New Swift files

- `app/CatalinaPerformance/Sources/CatalinaPerformance/ForegroundSession.swift` — models, exclusions, running-app filtering, preference serialization, and runtime-summary parsing.
- `app/CatalinaPerformance/Sources/CatalinaPerformance/ForegroundSessionPanelController.swift` — Advanced-section UI and callbacks.
- `app/CatalinaPerformance/Sources/CatalinaPerformance/ScriptSequenceCoordinator.swift` — serial execution and rollback ordering independent of AppKit views.
- `app/CatalinaPerformance/Tests/CatalinaPerformanceTests/ForegroundSessionTests.swift` — bundle filtering, serialization, summary parsing, and sequence tests.

### Modified files

- `app/CatalinaPerformance/Package.swift` — add the XCTest target.
- `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift` — add script kinds, sequence integration, Advanced panel insertion, and callbacks without moving system-changing behavior into Swift.
- `scripts/package_app.sh` — require all new runtime scripts and the shared library.
- `README.md` — document behavior, paths, safety, and local testing.
- `docs/KNOWN_ISSUES.md` — document save dialogs, relaunch limitations, and delayed animation effects.
- `docs/GUI_TESTING.md` — add manual session and rollback tests.
- `docs/TESTING_CHECKLIST.md` — add static, shell, Swift, and Catalina checks.

---

### Task 1: Add validated shared shell primitives and portable tests

**Files:**
- Create: `scripts/lib/foreground_session_common.sh`
- Create: `scripts/tests/test_foreground_session.sh`

**Interfaces:**
- Produces: `cp_foreground_root`, `cp_preferences_file`, `cp_runtime_dir`, `cp_logs_dir`, `cp_validate_bundle_id`, `cp_is_excluded_bundle_id`, `cp_sanitize_tsv_field`, `cp_read_boolean_preference`, `cp_selected_bundle_ids`, `cp_prepare_storage`, `cp_timestamp`, and command variables `CP_OSASCRIPT`, `CP_DEFAULTS`, `CP_OPEN`.
- Consumes: environment overrides `CATALINA_PERFORMANCE_FOREGROUND_DIR`, `CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE`, `CATALINA_PERFORMANCE_OSASCRIPT_BIN`, `CATALINA_PERFORMANCE_DEFAULTS_BIN`, and `CATALINA_PERFORMANCE_OPEN_BIN`.

- [ ] **Step 1: Write failing tests for paths, validation, exclusions, and preference parsing**

Create a test harness that sources the not-yet-created common library and checks these exact cases:

```sh
assert_equal "1" "$(cp_validate_bundle_id 'org.mozilla.firefox' && printf 1 || printf 0)" "valid bundle ID"
assert_equal "0" "$(cp_validate_bundle_id 'bad id;rm -rf /' && printf 1 || printf 0)" "reject unsafe bundle ID"
assert_equal "1" "$(cp_is_excluded_bundle_id 'com.apple.Terminal' && printf 1 || printf 0)" "exclude Terminal"
assert_equal "1" "$(cp_is_excluded_bundle_id 'com.googlecode.iterm2' && printf 1 || printf 0)" "exclude iTerm2"
assert_equal "0" "$(cp_is_excluded_bundle_id 'org.mozilla.firefox' && printf 1 || printf 0)" "allow Firefox"
```

The test must create a temporary `preferences.env` containing valid, duplicate, excluded, malformed, and unknown entries and assert that `cp_selected_bundle_ids` returns a sorted, unique list of only valid non-excluded identifiers.

- [ ] **Step 2: Run the test and verify it fails because the library is missing**

Run:

```sh
/bin/sh scripts/tests/test_foreground_session.sh
```

Expected: nonzero exit with a clear message that `scripts/lib/foreground_session_common.sh` cannot be sourced.

- [ ] **Step 3: Implement the common library**

Use strict bundle-ID validation and literal line parsing:

```sh
cp_validate_bundle_id() {
    case "$1" in
        ''|*[!A-Za-z0-9.-]*|.*|*..*|*.) return 1 ;;
        *) return 0 ;;
    esac
}

cp_is_excluded_bundle_id() {
    case "$1" in
        local.CatalinaPerformance|com.apple.Terminal|com.googlecode.iterm2|com.apple.finder|com.apple.dock|com.apple.systemuiserver|com.apple.WindowServer|com.apple.loginwindow)
            return 0
            ;;
        *) return 1 ;;
    esac
}
```

`cp_selected_bundle_ids` must read only repeated `SELECTED_BUNDLE_ID=` lines, trim surrounding whitespace, validate each value, exclude protected IDs, and deduplicate with `awk`; it must not source the file.

`cp_prepare_storage` must create the root, runtime, and logs directories with mode `700`, create a probe file, read it back, remove it, and fail before any changes when that round trip is unsuccessful.

- [ ] **Step 4: Run the common-library tests**

Run:

```sh
/bin/sh scripts/tests/test_foreground_session.sh common
```

Expected: all common-library assertions pass.

- [ ] **Step 5: Syntax-check and commit**

Run:

```sh
/bin/sh -n scripts/lib/foreground_session_common.sh
/bin/sh -n scripts/tests/test_foreground_session.sh
git diff --check
git add scripts/lib/foreground_session_common.sh scripts/tests/test_foreground_session.sh
git commit -m "test: add foreground session shell primitives"
```

---

### Task 2: Implement eligible-application listing and state inspection

**Files:**
- Create: `scripts/foreground_session_list.sh`
- Create: `scripts/foreground_session_state.sh`
- Modify: `scripts/tests/test_foreground_session.sh`

**Interfaces:**
- Consumes: common-library functions from Task 1.
- Produces: tab-separated list output with columns `display_name`, `bundle_identifier`, `running`; state summary keys `selected`, `running_before`, `confirmed_closed`, `skipped`, `pending_relaunch`, `relaunch_failed`.

- [ ] **Step 1: Add failing fixture-driven listing tests**

Use `CATALINA_PERFORMANCE_RUNNING_APPS_FILE` to supply deterministic raw rows:

```text
TextEdit	com.apple.TextEdit
Terminal	com.apple.Terminal
Firefox	org.mozilla.firefox
Missing ID	
CatalinaPerformance	local.CatalinaPerformance
```

Assert that list output contains TextEdit and Firefox, excludes Terminal and CatalinaPerformance, rejects the missing identifier, and is sorted by display name.

- [ ] **Step 2: Run the listing test and verify failure**

Run:

```sh
/bin/sh scripts/tests/test_foreground_session.sh list
```

Expected: nonzero because `foreground_session_list.sh` does not exist.

- [ ] **Step 3: Implement `foreground_session_list.sh`**

When the fixture variable is present, read it directly. Otherwise call `/usr/bin/osascript` with a static AppleScript that emits only GUI processes with a display name and bundle identifier. Normalize each row through `cp_sanitize_tsv_field`, validate the bundle ID, apply permanent exclusions, and print:

```text
display_name	bundle_identifier	running
Firefox	org.mozilla.firefox	1
TextEdit	com.apple.TextEdit	1
```

Failure to query running applications must produce a clear nonzero result without changing state.

- [ ] **Step 4: Add and test `foreground_session_state.sh`**

The state script must be read-only. With no runtime state, print zero counts and `session_active=0`. With fixture rows, calculate counts from fixed TSV columns instead of executing file contents.

Example output:

```text
session_active=1
selected=2
running_before=2
confirmed_closed=1
skipped=1
pending_relaunch=1
relaunch_failed=0
```

Run:

```sh
/bin/sh scripts/tests/test_foreground_session.sh list
/bin/sh scripts/tests/test_foreground_session.sh state
```

Expected: PASS.

- [ ] **Step 5: Syntax-check and commit**

Run:

```sh
/bin/sh -n scripts/foreground_session_list.sh
/bin/sh -n scripts/foreground_session_state.sh
/bin/sh -n scripts/tests/test_foreground_session.sh
git diff --check
git add scripts/foreground_session_list.sh scripts/foreground_session_state.sh scripts/tests/test_foreground_session.sh
git commit -m "feat: list eligible foreground applications"
```

---

### Task 3: Implement graceful application apply and selective restore

**Files:**
- Create: `scripts/foreground_session_apply.sh`
- Create: `scripts/foreground_session_restore.sh`
- Modify: `scripts/tests/test_foreground_session.sh`

**Interfaces:**
- Consumes: `SELECTED_BUNDLE_ID=` preferences, common-library paths/validation, static AppleScript quit/running checks, and `/usr/bin/open -b` for relaunch.
- Produces: `runtime/session.env`, `runtime/applications.tsv`, `logs/apply.log`, and `logs/restore.log`.

- [ ] **Step 1: Add failing apply tests using fake commands**

Create test-local fake commands whose behavior is controlled by files under the temporary test directory. The fake `osascript` must support `is running` and `quit`; the fake `open` must record bundle IDs and optionally fail.

Assert:

```text
- --dry-run never creates an active session and never requests quit.
- an unwritable runtime directory exits nonzero before any quit request.
- only selected, valid, non-excluded running applications receive a quit request.
- confirmed exit sets closed_by_catalina_performance=1.
- refusal or timeout remains closed_by_catalina_performance=0 and is nonfatal.
- an already-active runtime session is not overwritten.
```

- [ ] **Step 2: Run apply tests and verify failure**

Run:

```sh
/bin/sh scripts/tests/test_foreground_session.sh apply
```

Expected: nonzero because the apply script does not exist.

- [ ] **Step 3: Implement `foreground_session_apply.sh`**

Support `--dry-run`, `--yes`, and a bounded timeout defaulting to 10 seconds. Build AppleScript only after strict bundle-ID validation:

```sh
cp_application_is_running() {
    bundle_id=$1
    result=$($CP_OSASCRIPT -e "application id \"$bundle_id\" is running" 2>/dev/null || printf false)
    [ "$result" = "true" ]
}

cp_request_graceful_quit() {
    bundle_id=$1
    $CP_OSASCRIPT -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1
}
```

Before the first quit request, create and read back `session.env` and `applications.tsv`. Record one row per selected ID before mutation using fixed columns:

```text
bundle_identifier	display_name	was_running	quit_requested	confirmed_closed	should_relaunch	relaunch_result
```

Update rows through a temporary file and atomic `mv`; never edit state with `eval` or execute it as shell.

- [ ] **Step 4: Add failing restore tests**

Assert that restore:

```text
- relaunches only rows with was_running=1, quit_requested=1, confirmed_closed=1, should_relaunch=1.
- skips applications already running.
- never relaunches refused or unselected applications.
- records success, skip, or failure per row.
- preserves session_active=1 when any relaunch fails.
- marks session_active=0 only when all eligible restores are complete.
- supports --dry-run without changing state or launching applications.
```

- [ ] **Step 5: Implement `foreground_session_restore.sh` and run tests**

Relaunch with:

```sh
$CP_OPEN -b "$bundle_id"
```

Then verify running state with the same read-only test. Preserve failed rows for retry.

Run:

```sh
/bin/sh scripts/tests/test_foreground_session.sh apply
/bin/sh scripts/tests/test_foreground_session.sh restore
```

Expected: PASS.

- [ ] **Step 6: Syntax-check and commit**

Run:

```sh
/bin/sh -n scripts/foreground_session_apply.sh
/bin/sh -n scripts/foreground_session_restore.sh
/bin/sh -n scripts/tests/test_foreground_session.sh
git diff --check
git add scripts/foreground_session_apply.sh scripts/foreground_session_restore.sh scripts/tests/test_foreground_session.sh
git commit -m "feat: add reversible foreground app session"
```

---

### Task 4: Implement exact UI-responsiveness preference apply and restore

**Files:**
- Create: `scripts/ui_responsiveness_apply.sh`
- Create: `scripts/ui_responsiveness_restore.sh`
- Modify: `scripts/tests/test_foreground_session.sh`

**Interfaces:**
- Consumes: recognized booleans `DISABLE_FINDER_ANIMATIONS`, `SHORTEN_DOCK_ANIMATIONS`, and `DISABLE_WINDOW_ANIMATIONS` from `preferences.env`.
- Produces: `runtime/ui_preferences.tsv` with domain, key, prior existence, prior type, prior value, applied type, and applied value.

- [ ] **Step 1: Add failing fake-`defaults` tests**

Test these exact temporary preferences:

```text
com.apple.finder	DisableAllAnimations	bool	true
com.apple.dock	launchanim	bool	false
com.apple.dock	expose-animation-duration	float	0.1
NSGlobalDomain	NSAutomaticWindowAnimationsEnabled	bool	false
```

Cover prior boolean, integer, float, string, and absent values. Assert that unsupported prior types are skipped before mutation and logged clearly.

- [ ] **Step 2: Run UI-preference tests and verify failure**

Run:

```sh
/bin/sh scripts/tests/test_foreground_session.sh ui
```

Expected: nonzero because the UI scripts do not exist.

- [ ] **Step 3: Implement `ui_responsiveness_apply.sh`**

For each enabled known preference:

1. Query existence with `defaults read`.
2. Query type with `defaults read-type` when present.
3. Save the exact scalar value and type.
4. Write the state row atomically.
5. Apply only after the state row is readable.

If an apply fails after earlier keys changed, call the restore script immediately for the rows already recorded and exit nonzero. Do not restart, signal, or kill Finder or Dock in this patch; document that some Dock/Finder changes may take effect after those components naturally restart.

- [ ] **Step 4: Implement exact restore behavior**

Map saved scalar types to explicit `defaults write` flags:

```sh
case "$previous_type" in
    bool)   $CP_DEFAULTS write "$domain" "$key" -bool "$previous_value" ;;
    int)    $CP_DEFAULTS write "$domain" "$key" -int "$previous_value" ;;
    float)  $CP_DEFAULTS write "$domain" "$key" -float "$previous_value" ;;
    string) $CP_DEFAULTS write "$domain" "$key" -string "$previous_value" ;;
    absent) $CP_DEFAULTS delete "$domain" "$key" ;;
    *)      return 1 ;;
esac
```

Delete a key only when prior existence was false. Preserve failed rows for retry.

- [ ] **Step 5: Run tests, syntax checks, and commit**

Run:

```sh
/bin/sh scripts/tests/test_foreground_session.sh ui
/bin/sh -n scripts/ui_responsiveness_apply.sh
/bin/sh -n scripts/ui_responsiveness_restore.sh
git diff --check
git add scripts/ui_responsiveness_apply.sh scripts/ui_responsiveness_restore.sh scripts/tests/test_foreground_session.sh
git commit -m "feat: add reversible UI responsiveness settings"
```

---

### Task 5: Add Swift models, preference serialization, and the Advanced UI section

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformance/ForegroundSession.swift`
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformance/ForegroundSessionPanelController.swift`
- Create: `app/CatalinaPerformance/Tests/CatalinaPerformanceTests/ForegroundSessionTests.swift`
- Modify: `app/CatalinaPerformance/Package.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`

**Interfaces:**
- Produces: `ForegroundApplication`, `ForegroundApplicationFilter`, `ForegroundSessionPreferences`, `ForegroundSessionSummary`, and `ForegroundSessionPanelController` callbacks.
- Consumes: `NSWorkspace.shared.runningApplications`, `UserDefaults`, and Application Support paths.

- [ ] **Step 1: Add the XCTest target and failing pure-model tests**

Update `Package.swift`:

```swift
.testTarget(
    name: "CatalinaPerformanceTests",
    dependencies: ["CatalinaPerformance"]
)
```

Test exact permanent exclusions, missing bundle identifiers, background-only apps, duplicate IDs, sorted display order, safe serialization, and summary parsing.

Example:

```swift
func testTerminalAndITermArePermanentlyExcluded() {
    XCTAssertTrue(ForegroundApplicationFilter.isExcluded(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal"))
    XCTAssertTrue(ForegroundApplicationFilter.isExcluded(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm2"))
    XCTAssertFalse(ForegroundApplicationFilter.isExcluded(bundleIdentifier: "org.mozilla.firefox", displayName: "Firefox"))
}
```

- [ ] **Step 2: Run Swift tests and verify failure**

Run from `app/CatalinaPerformance`:

```sh
swift test
```

Expected: compile failure because foreground-session types are missing.

- [ ] **Step 3: Implement models and preference writer**

`ForegroundSessionPreferences` must register:

```swift
featureEnabled = false
disableFinderAnimations = true
shortenDockAnimations = true
disableWindowAnimations = true
selectedBundleIdentifiers = []
```

Write `preferences.env` atomically with recognized scalar keys followed by sorted repeated lines:

```text
FOREGROUND_SESSION_ENABLED=0
DISABLE_FINDER_ANIMATIONS=1
SHORTEN_DOCK_ANIMATIONS=1
DISABLE_WINDOW_ANIMATIONS=1
SELECTED_BUNDLE_ID=org.mozilla.firefox
```

Validate bundle IDs and apply permanent exclusions before writing.

- [ ] **Step 4: Implement the Advanced panel controller**

Create a self-contained view controller with:

```text
- opt-in feature checkbox
- Refresh Running Applications
- scrollable checkbox list showing name and bundle identifier
- three UI-responsiveness checkboxes
- Dry Run Performance Session
- Apply Performance Session Now
- Restore Performance Session
- View Foreground Session State
- selected/closed/skipped/pending summary label
```

Use `NSWorkspace.shared.runningApplications`, require activation policy `.regular`, and exclude terminated, hidden-system, protected, missing-ID, and duplicate entries. Each checkbox change must update `UserDefaults` and atomically rewrite the script configuration without running system changes.

- [ ] **Step 5: Insert the panel into the existing scrollable Advanced window**

Add it between Power Behavior and App Priority. Pass callbacks upward to `MainWindowController`; do not invoke scripts directly from the panel. Extend `setScriptActionsEnabled(_:)` so all new action buttons disable while any CatalinaPerformance action is running.

- [ ] **Step 6: Run tests/build and commit**

Run:

```sh
cd app/CatalinaPerformance
swift test
swift build
cd ../..
git diff --check
git add app/CatalinaPerformance/Package.swift app/CatalinaPerformance/Sources/CatalinaPerformance/ForegroundSession.swift app/CatalinaPerformance/Sources/CatalinaPerformance/ForegroundSessionPanelController.swift app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift app/CatalinaPerformance/Tests/CatalinaPerformanceTests/ForegroundSessionTests.swift
git commit -m "feat: add foreground session Advanced UI"
```

---

### Task 6: Add serial script sequencing and Performance Mode rollback integration

**Files:**
- Create: `app/CatalinaPerformance/Sources/CatalinaPerformance/ScriptSequenceCoordinator.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Modify: `app/CatalinaPerformance/Tests/CatalinaPerformanceTests/ForegroundSessionTests.swift`

**Interfaces:**
- Produces: `ScriptExecuting`, `ScriptSequenceStep`, `ScriptSequenceResult`, and `ScriptSequenceCoordinator.run(steps:completion:)`.
- Consumes: existing `ScriptRunner`, `ScriptKind`, and `ScriptResult`.

- [ ] **Step 1: Add failing sequence-order tests with a fake runner**

Test these exact flows:

```text
Feature disabled ON: performanceOn
Feature enabled ON success: foregroundApply -> uiApply -> performanceOn
Feature enabled ON, uiApply failure: foregroundApply -> uiApply -> foregroundRestore
Feature enabled ON, performanceOn failure: foregroundApply -> uiApply -> performanceOn -> uiRestore -> foregroundRestore
Feature enabled OFF: performanceOff -> uiRestore -> foregroundRestore, continuing user-level restore even when performanceOff fails
Manual dry run: foregroundApplyDryRun -> uiApplyDryRun
Manual apply: foregroundApply -> uiApply, with foregroundRestore rollback on UI failure
Manual restore: uiRestore -> foregroundRestore
```

The fake runner must complete asynchronously and assert completion is called exactly once.

- [ ] **Step 2: Run tests and verify failure**

Run:

```sh
cd app/CatalinaPerformance
swift test --filter ForegroundSessionTests
```

Expected: compile failure because the coordinator does not exist.

- [ ] **Step 3: Implement script kinds and coordinator**

Add explicit non-privileged cases:

```swift
case foregroundList
case foregroundApply
case foregroundApplyDryRun
case foregroundRestore
case foregroundRestoreDryRun
case foregroundState
case uiResponsivenessApply
case uiResponsivenessApplyDryRun
case uiResponsivenessRestore
case uiResponsivenessRestoreDryRun
```

Only `.performanceOn`, `.performanceOff`, and `.emergencyRestore` remain administrator-authorized. Pass `CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE` to direct scripts.

The coordinator must execute one step at a time and return all results in order. Rollback steps are explicit data, not hidden system-changing logic.

- [ ] **Step 4: Integrate ON/OFF and manual actions**

Replace the single-script ON action with feature-aware sequencing while keeping the existing confirmation. Acquire the existing `activeScriptCount` lock once for the whole sequence, append each exact command and result, and release once after final rollback or completion.

For ON failure after user-level changes, run rollback automatically and report both the primary failure and rollback outcome. For OFF, always attempt UI and application restore after the system-level OFF attempt; never mask a successful system restore with a user-level relaunch failure.

- [ ] **Step 5: Verify all lock and status paths**

Tests must assert that cancellation, timeout, failure, and rollback completion each produce one final sequence result. In the GUI, `defer`-equivalent completion handling must decrement `activeScriptCount` on every path.

- [ ] **Step 6: Run tests/build and commit**

Run:

```sh
cd app/CatalinaPerformance
swift test
swift build
cd ../..
git diff --check
git add app/CatalinaPerformance/Sources/CatalinaPerformance/ScriptSequenceCoordinator.swift app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift app/CatalinaPerformance/Tests/CatalinaPerformanceTests/ForegroundSessionTests.swift
git commit -m "feat: integrate foreground session with Performance Mode"
```

---

### Task 7: Package, document, and run full verification

**Files:**
- Modify: `scripts/package_app.sh`
- Modify: `README.md`
- Modify: `docs/KNOWN_ISSUES.md`
- Modify: `docs/GUI_TESTING.md`
- Modify: `docs/TESTING_CHECKLIST.md`

**Interfaces:**
- Consumes: all new scripts and Swift behavior.
- Produces: documented local build/test workflow and package-time missing-file checks.

- [ ] **Step 1: Make packaging require the new runtime files**

Add `require_executable_or_file` checks for all foreground-session and UI scripts plus `scripts/lib/foreground_session_common.sh`. Keep the existing repository-backed launcher model unchanged.

- [ ] **Step 2: Update documentation with exact behavior and paths**

Document:

```text
~/Library/Application Support/CatalinaPerformance/foreground_session/preferences.env
~/Library/Application Support/CatalinaPerformance/foreground_session/runtime/
~/Library/Application Support/CatalinaPerformance/foreground_session/logs/
```

State clearly that the feature is opt-in, uses normal quit requests, never force-quits, excludes Terminal/iTerm, restores only confirmed-closed apps, may not restore identical windows, and may leave UI preference changes pending until Dock/Finder naturally restart.

- [ ] **Step 3: Add the Catalina manual test matrix**

Include TextEdit and Calculator success tests, a save-dialog/refusal test, already-running restore skip, failed relaunch retry, unwritable state abort, exact preference restoration, ON privileged-failure rollback, OFF partial-failure reporting, and confirmation that legacy status/ON/OFF/Emergency/Memory/App Priority/Thermal actions still work.

- [ ] **Step 4: Run all static and portable verification**

Run:

```sh
git diff --check
/bin/sh -n scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh
/bin/sh scripts/tests/test_foreground_session.sh all
cd app/CatalinaPerformance
swift test
swift build
cd ../..
```

Expected: all checks pass. On non-macOS, AppKit-specific runtime behavior remains unexecuted, while pure Swift and fixture-driven shell tests pass.

- [ ] **Step 5: Run Catalina package verification**

On the Catalina development Mac:

```sh
./scripts/build_gui.sh
./scripts/package_app.sh
open ./build/CatalinaPerformance.app
```

Complete the documented GUI matrix. Confirm no foreground-session script requests sudo and the existing Performance ON/OFF authorization behavior is unchanged.

- [ ] **Step 6: Commit documentation and packaging changes**

Run:

```sh
git add scripts/package_app.sh README.md docs/KNOWN_ISSUES.md docs/GUI_TESTING.md docs/TESTING_CHECKLIST.md
git commit -m "docs: document foreground performance sessions"
```

- [ ] **Step 7: Final branch review before PR**

Run:

```sh
git status --short
git log --oneline --decorate -8
git diff main...HEAD --check
```

Review the complete diff for prohibited commands (`kill`, `killall`, `renice`, `sudo` in new user-level scripts, `eval`, fan/SMC/SIP/MSR/kext changes). Open a pull request only after the branch is clean and the verification evidence is recorded in the PR body.
