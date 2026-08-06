# Background Service Suppression Design

**Project:** CatalinaPerformance
**Date:** 2026-08-01
**Status:** Approved design

## 1. Purpose

Add a reversible Background Service Suppression subsystem to CatalinaPerformance. While Performance Mode is ON, the subsystem reduces nonessential Apple background activity that the user does not use, without interfering with iCloud Keychain, Safari passwords, AirDrop, networking, diagnostics, or other protected system functions.

The feature targets CPU, memory, disk, and network work from inactive Apple services. It does not claim that every session will be faster. The Session Dashboard reports what was suppressed, resumed, skipped, or restored so the user can compare results.

## 2. Approved User Profile

The design is based on the following confirmed usage:

- iCloud Drive: not used.
- iCloud Photos: not used.
- Apple Photos: not used.
- Siri, Dictation, and voice input: not used.
- Apple Mail: not used.
- Messages and FaceTime: not used.
- Find My Mac: not used.
- iCloud Keychain and Safari password synchronization: used and must remain protected.
- macOS automatic update checks and downloads: may be paused during Performance Mode.
- Mac App Store background checks and automatic downloads: may be paused during Performance Mode.
- Diagnostics and crash reporting: must remain untouched.

## 3. Scope

### 3.1 Automatic suppression

Performance Mode automatically manages these categories:

1. macOS automatic update checks and downloads.
2. Mac App Store background update checks and automatic downloads.
3. Photos analysis and media-library workers.
4. Mail fetching and indexing workers.
5. Messages and FaceTime synchronization workers.
6. Siri, Dictation, and speech-recognition workers.

### 3.2 Optional suppression

The Advanced panel contains one explicit opt-in setting:

```text
[ ] Pause iCloud Drive synchronization while Performance Mode is ON
```

It defaults to OFF. iCloud Drive remains separate because its workers overlap more heavily with Apple account and CloudKit infrastructure.

### 3.3 Permanently protected services

The subsystem must never intentionally stop, unload, disable, or modify:

- iCloud Keychain synchronization.
- Safari password and AutoFill synchronization.
- `securityd`.
- `trustd`.
- `accountsd`.
- Shared CloudKit account services.
- Apple push-notification infrastructure.
- AirDrop and its required sharing services.
- Networking, DNS, DHCP, and Wi-Fi services.
- Finder, Dock, WindowServer, SystemUIServer, loginwindow, or launchd.
- Audio, microphone routing, and accessibility services.
- Diagnostics, crash reporting, and log collection.
- Any root-owned or system-critical process not explicitly listed in the Catalina target catalog.

Broad operations such as "disable iCloud," wildcard process matching, blanket `killall`, deleting launch-agent files, or permanently changing launch-service configuration are prohibited.

## 4. Architecture

The feature is divided into four isolated components.

### 4.1 Policy and state core

A pure Swift module defines:

- Target categories.
- Protected-service rules.
- Exact target identities.
- Session state.
- Apply, resume, and restore outcomes.
- Dashboard presentation data.

This module performs no system mutation and is testable without AppKit or macOS process APIs.

### 4.2 Catalina target catalog

A versioned Catalina-only catalog maps each category to positively identified targets. Every target entry includes the information required to reject false matches:

- Launch-agent or service label, when applicable.
- Expected executable path or path prefix.
- Expected user domain and UID ownership.
- Associated user-facing application bundle identifiers.
- Whether the target can be stopped, resumed, and verified reliably.
- Whether administrative authorization is required.

The implementation may include a target only after a Catalina probe confirms a reliable read, apply, verify, and restore path. An uncertain target is reported as Unsupported and is not mutated.

The catalog must not use fuzzy names, substring-only matching, or a rule that treats every process from an Apple framework as eligible.

### 4.3 Suppression coordinator

A coordinator in the main application controls the subsystem lifecycle:

- Runs preflight validation before Performance Mode changes begin.
- Captures original settings and worker state before mutation.
- Invokes narrow apply and restore operations.
- Watches for user-facing applications or activation processes.
- Marks categories as resumed for the remainder of the session.
- Publishes live state to the Session Dashboard.

AppKit and `NSWorkspace` are used only for application lifecycle observation and UI updates. Blocking process discovery, command execution, parsing, and file I/O must stay off the AppKit main thread.

### 4.4 Narrow system-operation boundary

System-changing operations live behind a small reviewed interface, implemented with dedicated scripts or a narrow helper consistent with the existing CatalinaPerformance authorization model.

Expected operations are:

- Read current update preferences and worker state.
- Apply a category-specific temporary suppression.
- Verify that suppression took effect.
- Resume one category after user activity.
- Restore one category to its recorded original state.
- Verify restoration.

There is no generic "run arbitrary launchctl command" interface.

## 5. Session State

State is stored under the existing CatalinaPerformance Application Support area in a dedicated versioned directory:

```text
~/Library/Application Support/CatalinaPerformance/background_service_suppression/
```

The active session record contains:

- Schema version.
- Session identifier.
- User UID.
- Start timestamp.
- Requested automatic and optional categories.
- Original setting values for software updates and App Store updates.
- Per-worker identity and original running state.
- Apply result and verification result.
- Whether an associated application was opened.
- Resume reason and timestamp.
- Restore result and verification result.
- Outstanding restoration work.

State files are written atomically with restrictive user permissions. A category is never marked suppressed until its state was captured and the change was verified.

## 6. Performance Mode ON Flow

1. Confirm macOS Catalina compatibility and the current user identity.
2. Load the versioned target catalog.
3. Reject the session if any configured target overlaps the protected-service rules.
4. Read all required original settings and worker states.
5. Write the initial session record atomically.
6. Apply automatic categories one at a time.
7. Apply iCloud Drive only when its Advanced option is enabled.
8. Verify each category independently.
9. Record success, skip, unsupported, or failure for every category.
10. Start the application-activity observer and eligible-worker monitor.
11. Publish the resulting state to the main UI and Session Dashboard.

A failure in one isolated category restores that category and allows other verified categories to continue. A failure in shared state capture, protected-service validation, or session persistence aborts the entire suppression subsystem before mutation. Core Performance Mode may continue, but the UI must report Background Service Suppression as unavailable or degraded rather than fully active.

## 7. Suppression Mechanics

The implementation uses the least intrusive reliable mechanism for each target:

1. Prefer an existing Catalina setting or supported service-control path with readable prior state.
2. Prefer a normal service stop or termination request over stronger process termination.
3. Use a stronger user-level stop only after validating UID, executable identity, service label, and session state.
4. Never use SIGKILL as the normal suppression path.
5. Never unload or delete a persistent launch-agent definition.
6. Never modify a protected service as a dependency workaround.

Workers that macOS automatically relaunches may be re-suppressed only while their category remains eligible and no associated user-facing application has been opened during the session.

## 8. Dynamic Resume Behavior

Opening or activating a related user-facing feature permanently exempts that category for the remainder of the current Performance Mode session.

### 8.1 Resume triggers

- Opening Photos resumes Photos analysis and media-library workers.
- Opening Mail resumes Mail fetching and indexing workers.
- Opening Messages or FaceTime resumes Messages and FaceTime synchronization workers.
- Activating Siri, Dictation, or voice input resumes Siri and speech-recognition workers.
- Opening the Mac App Store resumes App Store background services needed for manual use.
- Opening Software Update in System Preferences resumes the macOS update category needed for manual use.
- Opening or actively using iCloud Drive resumes iCloud Drive workers when optional suppression was enabled.

### 8.2 Session rule

After a category resumes because of user activity:

- CatalinaPerformance does not suppress it again during that session.
- The dashboard records `Resumed — user opened <application or feature>`.
- Performance Mode OFF restores only any remaining recorded setting differences.
- The category becomes eligible again at the start of the next Performance Mode session.

This prevents CatalinaPerformance from fighting an application the user deliberately opened.

## 9. Performance Mode OFF and Emergency Restore

OFF performs category restoration before deleting active session state:

1. Stop monitoring and prevent new suppression attempts.
2. Read the active session record.
3. Restore exact original update and App Store preference values.
4. Restore only workers CatalinaPerformance successfully stopped and that still match their recorded identity.
5. Do not restart workers that were not running before suppression unless a reliable system setting requires normal relaunch behavior.
6. Verify every restoration.
7. Remove completed category records only after successful verification.
8. Preserve failed or unverifiable records for retry.
9. Mark the completed session for dashboard reporting.

Emergency Restore uses the same recorded state and narrow restore operations. It may use conservative Catalina defaults only when the original state is missing and the fallback is explicitly documented. It must never broadly enable or disable unrelated Apple services.

## 10. Stale Session Recovery

At application launch, the coordinator checks for an unfinished suppression session.

- When no matching Performance Mode session is active, restoration is offered or attempted through the existing recovery flow.
- PID reuse and changed executable identity are treated as mismatches and are never mutated.
- Settings with recorded original values are restored even after application termination.
- A reboot naturally ends individual processes, but persistent setting differences still require verification and restoration.
- The app must display outstanding restoration items until they are resolved or explicitly dismissed with a clear warning.

## 11. Advanced UI

The Advanced panel contains a Background Service Suppression section:

```text
Background Service Suppression

Automatic while Performance Mode is ON:
✓ macOS automatic updates
✓ App Store background updates
✓ Photos background workers
✓ Mail background workers
✓ Messages and FaceTime workers
✓ Siri, Dictation, and speech workers

Optional:
[ ] Pause iCloud Drive synchronization

Protected:
iCloud Keychain, Safari passwords, AirDrop, networking,
diagnostics, crash reporting, and essential macOS services

Status: Off / Active / Degraded / Restoring / Recovery required
```

The automatic list is explanatory rather than individually configurable in this feature revision. The iCloud Drive option is disabled while Performance Mode is active to avoid mid-session policy ambiguity.

## 12. Dashboard Reporting

The Session Dashboard shows each category separately. Examples:

```text
macOS Updates                 Paused
App Store Updates             Resumed — App Store opened
Photos Workers                Paused
Mail Workers                  Paused
Messages / FaceTime Workers   Paused
Siri / Speech Workers         Unsupported
iCloud Drive                  Not configured
```

For each category the dashboard may show:

- Original state captured.
- Requested action.
- Suppression result.
- Verification result.
- Dynamic resume reason.
- Restoration result.
- Remaining recovery requirement.

The dashboard must distinguish `Not configured`, `Unsupported`, `Skipped`, `Paused`, `Resumed by user`, `Restored`, and `Restore failed`. It must not convert missing evidence into a successful status.

## 13. Failure Handling

- No mutation occurs without saved original state and a known restore path.
- Protected-service overlap aborts the subsystem.
- A category-level failure triggers immediate rollback for that category.
- A failed rollback is retained as outstanding recovery state.
- Repeated ON is idempotent and does not overwrite the original baseline.
- Repeated OFF is safe and retries only outstanding restoration work.
- The main UI reports partial success accurately.
- Logs include target category and result but do not include passwords, tokens, message content, mail content, or other personal data.

## 14. Security and Privacy

- Prefer user-level control; elevate only operations that require it.
- Reuse the existing explicit administrator-authorization flow rather than installing a broad permanent daemon.
- Validate UID, executable path, service label, and process start identity before process mutation.
- Do not inspect Photos, Mail, Messages, FaceTime, Keychain, Safari, or iCloud user content.
- Do not transmit telemetry.
- Do not alter SIP, kexts, SMC, MSRs, firmware, or fan control.

## 15. Compatibility

- Target macOS Catalina and the repository's supported Xcode/Swift toolchain.
- Avoid newer Swift syntax and macOS APIs unavailable on Catalina.
- Keep shell code POSIX-compatible unless a documented exception is necessary.
- Tests on non-macOS systems use fixtures and pure policy logic; actual service mutation is never attempted there.

## 16. Testing Requirements

### 16.1 Pure Swift tests

- Target catalog decoding and version handling.
- Protected-service rejection.
- Category policy selection.
- State serialization and atomic recovery semantics.
- Dynamic resume for every application category.
- Session-long exemption after user resume.
- Idempotent ON and OFF behavior.
- Dashboard status classification.

### 16.2 Script and source-contract tests

- Every apply operation has a matching restore operation.
- No wildcard `killall` or broad iCloud-disable command.
- No protected service appears in a mutable target list.
- No launch-agent plist deletion or persistent unload behavior.
- No SIGKILL normal path.
- Unknown or malformed target entries fail closed.
- Shell syntax and `git diff --check` pass.

### 16.3 Catalina integration tests

For each supported category:

1. Capture baseline setting and worker state.
2. Turn Performance Mode ON.
3. Confirm only the expected target is suppressed.
4. Confirm protected Keychain and Safari password synchronization remain functional.
5. Open the associated application or feature.
6. Confirm the category resumes and remains exempt for the session.
7. Turn Performance Mode OFF.
8. Confirm exact restoration and dashboard evidence.
9. Repeat ON/OFF to verify idempotency.
10. Terminate CatalinaPerformance during an active session and verify stale-session recovery.
11. Exercise Emergency Restore with both complete and partially missing state.

Manual checks must also verify AirDrop, networking, push notifications, diagnostics, and crash reporting remain unaffected.

## 17. Non-Goals

This feature does not:

- Disable all iCloud services.
- Modify iCloud Keychain or Safari password synchronization.
- Delete caches or user data.
- Permanently disable launch agents or daemons.
- Suppress third-party applications.
- Change Firefox App Priority behavior.
- Control fans, temperatures, Turbo Boost, voltage, or hardware clocks.
- Guarantee a performance improvement without measurement.

## 18. Acceptance Criteria

The feature is complete only when:

- All automatic categories have explicit Catalina target identities and reliable restore paths.
- iCloud Drive remains opt-in and defaults OFF.
- Protected-service contract tests pass.
- Dynamic resume works for every supported user-facing application or feature.
- OFF and Emergency Restore return settings and eligible workers to recorded state.
- Stale-session recovery is verified on Catalina.
- Dashboard reporting accurately distinguishes all category outcomes.
- iCloud Keychain and Safari passwords remain operational during repeated test cycles.
- The full existing CatalinaPerformance regression suite passes.
