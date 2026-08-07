# Memory Pressure & Swap Management 1.0 — Catalina Runtime Acceptance

Target: macOS Catalina 10.15.7 build 19H15 on the validated Intel MacBook Pro.

This checklist validates behavior and restoration. It is not permission to exhaust physical memory, disable swap, run `purge`, kill applications automatically, or change kernel VM configuration.

## 1. Build and source-safety gate

From the repository root:

```bash
/bin/sh scripts/tests/test_memory_vm_probe_source.sh
/bin/sh scripts/tests/test_memory_taskpolicy_calibration_source.sh
/bin/sh scripts/tests/test_memory_management_production_wiring_source.sh
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

cd app/CatalinaPerformance
rm -rf .build
swift test
swift build --product CatalinaPerformance
swift build --product CatalinaPerformancePriorityAgent
swift build --product CatalinaPerformanceMemoryAgent
cd ../..
git diff --check
```

Acceptance:
- no test failure;
- no linker duplicate for `cp_read_vm_memory_info`;
- Memory Management wrapper/UI/production-wiring source contracts pass;
- both session-scoped agents build on Catalina/Xcode 12.4-era Swift;
- existing App Priority, Foreground Session, Background Service, and WindowServer contracts remain green;
- warnings may be recorded separately but may not hide a build/test failure.

## 2. Package validation

```bash
pkill -x CatalinaPerformance 2>/dev/null || true
pkill -x CatalinaPerformanceMemoryAgent 2>/dev/null || true
rm -rf build
/bin/sh scripts/package_app.sh
```

Verify packaged resources:

```bash
test -x build/CatalinaPerformance.app/Contents/Resources/bin/CatalinaPerformanceMemoryAgent
test -x build/CatalinaPerformance.app/Contents/Resources/bin/CatalinaPerformancePriorityAgent
test -x build/CatalinaPerformance.app/Contents/Resources/scripts/performance_on_with_priority.sh
test -x build/CatalinaPerformance.app/Contents/Resources/scripts/performance_off_with_priority.sh
test -x build/CatalinaPerformance.app/Contents/Resources/scripts/emergency_restore_with_priority.sh
test -x build/CatalinaPerformance.app/Contents/Resources/scripts/lib/memory_management_wrapper_common.sh
```

Launch:

```bash
open ./build/CatalinaPerformance.app
```

## 3. Advanced and Dashboard UI sanity

Open **Advanced** and confirm a separate **Memory Pressure Management** section exists.

Acceptance:
- automatically active with Performance Mode;
- CPU policy is fixed at `nice +5`;
- I/O policy reports **Unsupported on this Catalina target**;
- maximum managed workloads is 3;
- no nice slider, family-cap slider, swap target, compressor target, or VM threshold controls;
- the separate **Memory / Storage** button remains a read-only diagnostic.

Open **Session Dashboard** and confirm Memory Management appears in a dedicated **Memory / Swap** section rather than being mixed into generic System rows.

## 4. Idle/normal session

Turn Performance Mode ON using the normal UI and leave the machine under ordinary workload for at least two minutes.

Inspect:

```bash
UID_NOW=$(id -u)
STATUS="/var/run/CatalinaPerformance/$UID_NOW/memory_management/status.json"
DESIRED="$HOME/Library/Application Support/CatalinaPerformance/memory_management/desired-state.json"

printf '\n=== MEMORY AGENT STATUS ===\n'
cat "$STATUS" 2>/dev/null || echo 'status unavailable'
printf '\n=== DESIRED STATE ===\n'
cat "$DESIRED" 2>/dev/null || echo 'desired state unavailable'
printf '\n=== MEMORY AGENT PROCESS ===\n'
ps -axo pid,uid,ni,comm | grep '[C]atalinaPerformanceMemoryAgent' || true
```

Acceptance:
- a single counter spike never causes intervention;
- stable historical swap usage alone does not trigger intervention;
- Healthy/Elevated without confirmed High/Critical leaves desired families empty;
- no more than three families are ever reported managed;
- I/O policy reports Unsupported;
- `taskpolicy` is never invoked;
- ordinary high RAM use without corroborating VM pressure does not cause automatic mutation;
- Memory Agent is session-scoped and no LaunchDaemon/login item is installed.

## 5. Controlled pressure transition

Use normal applications to create a bounded, reversible memory-heavy workload. Prefer opening additional browser tabs/windows and another already-installed memory-heavy user application. Do not use an unbounded allocator or deliberately make the machine unresponsive.

Observe the existing two-second Session Dashboard cadence while increasing memory demand gradually.

Acceptance:
1. Healthy may become Elevated.
2. Elevated alone does not authorize mutation.
3. High requires three consecutive High candidates before intervention.
4. Critical requires two consecutive Critical candidates.
5. Family admission requires three background observations.
6. Each admitted family exceeds `max(256 MiB, 5% physical RAM)`.
7. At most three verified same-user noncritical application families enter desired state.
8. Managed eligible processes use nice `+5` unless already at an equal-or-more-deprioritized nice value.
9. `taskpolicy` remains unused/Unsupported.
10. No automatic app termination occurs.

Record:

```bash
printf '\n=== DESIRED STATE ===\n'
cat "$DESIRED" 2>/dev/null || true
printf '\n=== AGENT STATUS ===\n'
cat "$STATUS" 2>/dev/null || true
printf '\n=== USER PROCESSES / NICE ===\n'
ps -U "$USER" -o pid,ppid,uid,ni,rss,comm | sort -k5 -nr | head -30
```

Do not treat intervention itself as proof of performance improvement.

## 6. Foreground protection

While a background family is actively managed, bring that application to the foreground normally.

Acceptance:
- the foreground family is removed from desired state immediately;
- the Memory Agent restores its exact recorded original nice values before that family can be considered managed again;
- a reused PID or mismatched start/path identity is never mutated or restored by guesswork;
- a replacement family does not churn in and out on one sample.

## 7. App Priority conflict protection

Configure an App Priority target for a new session and repeat the pressure check.

Acceptance:
- the App Priority family never remains in Memory Management desired state;
- if it had been managed first, Memory Management requests restoration/removal before App Priority owns it;
- existing App Priority Firefox/family behavior remains unchanged.

## 8. Healthy recovery

After intervention is active, release the bounded pressure workload without turning Performance Mode off.

Acceptance:
- one Healthy sample does not restore;
- five consecutive Healthy samples are required;
- after the fifth Healthy sample, desired families become empty;
- all still-valid changed processes return to their exact recorded original nice values;
- exited processes are recorded as exited rather than treated as restore failures;
- unresolved restoration stays visible and retryable;
- Dashboard records the episode/restoration without claiming that a swap endpoint alone proves improvement.

## 9. Normal OFF

With Memory Management active if practical, turn Performance Mode OFF normally.

Acceptance:
- OFF bypasses Healthy hysteresis;
- Memory Agent `stop-and-restore` is attempted before core OFF;
- Memory restore is attempted even when App Priority is disabled;
- App Priority, Background Service, Visual Performance, foreground-app, and core restoration continue through their independent paths if one memory restore reports failure;
- no valid managed process remains at CatalinaPerformance's applied nice value after successful restoration;
- unresolved restoration remains persisted for retry rather than being discarded.

## 10. Emergency Restore

Repeat controlled pressure, then invoke **Emergency Restore**.

Acceptance mirrors normal OFF, and Emergency Restore continues the other restoration subsystems even if one Memory/App Priority/background step fails.

Confirm the feature introduced no new use of:
- `purge`;
- swap-file deletion or swap disabling;
- `sysctl -w` VM changes;
- `taskpolicy`;
- arbitrary process killing;
- LaunchDaemon installation.

## 11. Process exit and PID-reuse safety

During a controlled managed state:
1. Quit one managed background app normally.
2. Launch other applications so new PIDs are created.

Acceptance:
- the exited process is never restored through a newly reused PID;
- identity requires matching PID, UID, executable path, start seconds, and start microseconds;
- a mismatch is fail-closed.

## 12. Agent crash and stale-state recovery

Only after normal ON/OFF passes:
1. Start Performance Mode and reach an active Memory Management session.
2. If a real intervention is active, record desired state/status and relevant nice values.
3. Terminate only `CatalinaPerformanceMemoryAgent`.
4. Use Emergency Restore rather than manually editing state files.

Acceptance:
- root-owned runtime restoration state is retained when needed;
- recovery does not trust a reused PID;
- Emergency Restore can retry exact restoration;
- unresolved records remain visible when exact restoration cannot be proven.

Also test quitting/reopening CatalinaPerformance during an active Performance Mode session. Persisted desired/runtime state must not authorize new mutation from corrupt or unverifiable identity data.

## 13. Protected-infrastructure regression

During and after pressure testing confirm normal operation of:
- Finder and Dock;
- Wi-Fi/DNS/network access;
- AirDrop availability;
- Bluetooth;
- audio playback;
- Keychain/password/autofill functionality;
- WindowServer/SystemUIServer/login session;
- CatalinaPerformance itself.

No root-owned or protected infrastructure process may appear in Memory Management desired state.

## 14. Dashboard evidence

Active dashboard should report when available:
- State
- Physical Used
- Available
- Compressed
- Compression Growth
- Swap Used
- Swap Growth
- Swap In
- Swap Out
- Page-Out Activity
- Managed Workloads
- I/O Policy

Completed-session evidence should retain:
- baseline and maximum pressure state;
- baseline/peak compressed memory;
- baseline/peak/net swap;
- peak compression/swap-in/swap-out activity;
- time in Healthy/Elevated/High/Critical;
- intervention episodes;
- managed family names;
- longest intervention duration;
- restoration result.

## 15. Evidence interpretation

Do not claim success merely because swap decreased or because intervention activated. Compare repeated equivalent workloads where possible and record:
- swap growth rate;
- swap-out rate;
- compression growth;
- duration in High/Critical;
- UI responsiveness;
- foreground workload completion behavior.

A result is acceptable when the feature is safe and reversible even if a particular workload shows no performance benefit. Any claim that the policy improves responsiveness must be supported by repeated observations rather than one run.
