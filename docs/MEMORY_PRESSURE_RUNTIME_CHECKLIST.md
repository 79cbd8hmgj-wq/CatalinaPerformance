# Memory Pressure & Swap Management 1.0 — Catalina Runtime Acceptance

Target: macOS Catalina 10.15.7 build 19H15 on the validated Intel MacBook Pro.

This checklist validates behavior and restoration. It is not permission to exhaust physical memory, disable swap, run `purge`, kill applications automatically, or change kernel VM configuration.

## 1. Build and source-safety gate

From the repository root:

```bash
/bin/sh scripts/tests/test_memory_vm_probe_source.sh
/bin/sh scripts/tests/test_memory_taskpolicy_calibration_source.sh
/bin/sh scripts/tests/test_memory_management_wrappers.sh
/bin/sh scripts/tests/test_memory_management_ui_source.sh
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
/bin/sh scripts/tests/test_catalina_process_support_source.sh
/bin/sh scripts/tests/test_app_priority_wrappers.sh
/bin/sh scripts/tests/test_app_priority_ui_source.sh
/bin/sh scripts/tests/test_foreground_session.sh all
/bin/sh scripts/tests/test_advanced_layout_source.sh

cd app/CatalinaPerformance
swift test
swift build --product CatalinaPerformance
swift build --product CatalinaPerformancePriorityAgent
swift build --product CatalinaPerformanceMemoryAgent
cd ../..
```

Acceptance:
- no test failure;
- no linker duplicate for `cp_read_vm_memory_info`;
- Memory Management wrapper/UI source contracts pass;
- both session-scoped agents build on Catalina/Xcode 12.4-era Swift;
- warnings may be recorded separately but may not hide a build/test failure.

## 2. Idle/normal session

1. Close unnecessary applications and wait for the machine to settle.
2. Open CatalinaPerformance and the Session Dashboard.
3. Turn Performance Mode ON using the normal UI.
4. Leave the machine under ordinary light use for at least 60 seconds.

Record:
- Memory / Swap state;
- available and compressed memory;
- swap used and swap growth;
- swap-in/out rates;
- page-out activity;
- Memory Management status;
- managed workload count.

Acceptance:
- a single counter spike never causes intervention;
- stable historical swap usage alone does not trigger intervention;
- no more than three families are ever reported managed;
- I/O policy reports **Unsupported** on this target;
- `taskpolicy` is never invoked;
- ordinary high RAM use without corroborating VM pressure does not cause automatic mutation.

## 3. Controlled pressure transition

Use normal applications or a bounded disposable allocation workload. Do not allocate until the system becomes unresponsive and do not use destructive memory-exhaustion tools.

Observe the existing two-second Session Dashboard cadence while increasing memory demand gradually.

Acceptance:
- pressure moves through the classifier only from real sampled evidence;
- High requires three consecutive High candidates;
- Critical requires two consecutive Critical candidates;
- family admission requires three background observations;
- each admitted family exceeds `max(256 MiB, 5% physical RAM)`;
- only verified same-user noncritical application families qualify;
- intervention uses nice `+5` only and never raises a process above its original priority;
- no automatic app termination occurs.

## 4. Foreground protection

While one background family is actively managed:

1. Bring that application to the foreground.
2. Observe its Memory Management status and process nice values.

Acceptance:
- the foreground family is removed from desired state immediately;
- the Memory Agent restores its exact recorded original nice values before a replacement family can be applied;
- a reused PID or identity mismatch is never mutated or restored by guesswork.

## 5. App Priority conflict protection

While Memory Management is active:

1. Configure/select an eligible application as the App Priority target when configuration is permitted for the next session.
2. Start a new session and create controlled pressure.

Acceptance:
- the App Priority family never appears in Memory Management desired families;
- if a conflict is introduced by state transition, Memory Management restores/removes its policy before App Priority owns the family;
- App Priority behavior remains unchanged from its existing policy tests.

## 6. Healthy recovery

After intervention is active, release the bounded pressure workload and allow memory conditions to recover.

Acceptance:
- one healthy sample does not restore;
- five consecutive Healthy samples are required;
- after the recovery window, all still-valid managed processes return to their exact recorded nice values;
- exited processes are recorded as exited and are not treated as restore failures;
- unresolved restoration remains visible and retryable.

## 7. Normal OFF

With Memory Management active, turn Performance Mode OFF normally.

Acceptance:
- Memory Agent `stop-and-restore` runs even if App Priority is disabled;
- Memory restoration is attempted before core OFF completes;
- valid outstanding process priorities restore exactly;
- Background Service Suppression, App Priority, Visual Performance, foreground-app restoration, and core OFF continue through their existing independent recovery paths;
- no managed policy remains after successful OFF.

## 8. Emergency Restore

Repeat controlled pressure, then invoke Emergency Restore.

Acceptance:
- Memory Agent restoration is attempted even if another subsystem reports a restore error;
- valid outstanding memory-priority records are restored exactly;
- unresolved records remain preserved for retry rather than being deleted or guessed;
- AirDrop, Wi-Fi/DNS, Bluetooth, audio, Keychain/password services, Finder, Dock, WindowServer, SystemUIServer, and login/session infrastructure remain untouched.

## 9. Process exit and PID reuse safety

During a controlled managed state:

1. Quit one managed background app normally.
2. Launch other applications so new PIDs are created.

Acceptance:
- the exited process is never restored through a newly reused PID;
- identity requires matching PID, UID, executable path, start seconds, and start microseconds;
- a mismatch is fail-closed.

## 10. App relaunch / stale-session recovery

1. Start Performance Mode and create a managed state.
2. Quit CatalinaPerformance unexpectedly without intentionally terminating the Memory Agent.
3. Reopen CatalinaPerformance.
4. Use normal OFF or Emergency Restore as appropriate.

Acceptance:
- persisted desired/runtime state is recognized;
- no new mutation begins from corrupt/unverifiable state;
- outstanding valid records can still be restored;
- stale state is preserved when exact restoration cannot be proven.

## 11. Dashboard / Advanced UI acceptance

Confirm the Session Dashboard has a dedicated **Memory / Swap** area and Advanced contains **Memory Pressure Management** status.

Active dashboard should report, when available:
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

Advanced acceptance:
- text states that management is automatically active with Performance Mode;
- CPU policy is fixed at nice `+5`;
- maximum managed workloads is fixed at 3;
- I/O policy is Unsupported on this Catalina target;
- there are no controls for nice level, family cap, swap target, compressor target, or VM thresholds.

## 12. Evidence interpretation

Do not claim success merely because swap decreased or because the intervention activated. Compare repeated equivalent workloads where possible and record:
- swap growth rate;
- swap-out rate;
- compression growth;
- duration in High/Critical;
- UI responsiveness;
- foreground workload completion behavior.

A result is acceptable when the feature is safe and reversible even if a particular workload shows no performance benefit. Any claim that the policy improves responsiveness must be supported by repeated observations rather than one run.
