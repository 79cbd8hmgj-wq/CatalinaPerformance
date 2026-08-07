# Testing Checklist

Use this checklist as CatalinaPerformance evolves from documentation into scripts and app code.

## Repository Checks

- Documentation explains the current behavior accurately.
- Scripts are executable only when they are intended to be run.
- Shell scripts pass syntax checks.
- New behavior is covered by manual or automated testing notes.

## Platform Checks

- Confirm behavior on macOS Catalina 10.15.
- Confirm behavior on an Intel Mac.
- Confirm graceful handling on unsupported macOS versions.
- Confirm graceful handling on non-macOS systems when scripts are run during development.

## Performance Mode ON Checks

For each system tweak:

- Prior state is recorded before changes are applied.
- The change is temporary.
- The UI or script output reports the active state.
- Failure stops further changes or leaves a clear recovery path.

## Performance Mode OFF Checks

For each system tweak:

- The stored prior state is restored.
- Repeated OFF calls are safe.
- Restore failures are reported clearly.
- No permanent service disablement remains.

## Regression Checks

- Repeated ON/OFF cycles do not accumulate state.
- App quit or script interruption triggers documented cleanup where possible.
- Unsupported sensors or commands do not crash the app.
- No code path modifies SIP.
- No code path automatically deletes caches.

## Foreground Performance Session Automated Checks

- `/bin/sh -n scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh`
- `/bin/sh scripts/tests/test_foreground_session.sh all`
- `cd app/CatalinaPerformance && swift test && swift build`
- Eligible-app listing excludes all permanent exclusions and applications without safe bundle identifiers.
- Preferences parsing ignores unknown, malformed, duplicate, and excluded selections without sourcing or evaluating the file.
- Dry run sends no quit request, writes no active runtime state, launches no application, and changes no preference.
- Runtime storage is created and read back before the first quit request or preference write.
- Refused/timed-out applications remain unclosed and are never marked for relaunch.
- Restore launches only applications that were running, requested to quit, and confirmed closed by CatalinaPerformance.
- Already-running applications are skipped; failed relaunch state remains pending for retry.
- Existing boolean, integer, float, string, and absent preference states restore using explicit `defaults` types.
- Sequence tests cover ON success, ON rollback after privileged failure, OFF continuation after privileged failure, and exactly-once completion.

## Foreground Performance Session Catalina Checks

- Build with macOS Catalina 10.15 and Xcode 12.4.
- Verify the Advanced section remains readable and scrollable in light and dark mode.
- Verify NSWorkspace lists only regular GUI applications and selection persists by bundle identifier.
- Verify System Events/Automation permission failure is reported without changing state.
- Verify LaunchServices relaunch via `open -b` works for TextEdit and Calculator.
- Verify Finder/Dock are not killed, signaled, or forcibly restarted.
- Verify no foreground-session or UI-responsiveness script requests administrator authorization.
- Verify Performance ON/OFF and Emergency Restore authorization behavior is unchanged.

## Background Service Suppression Automated Checks

- `/bin/sh scripts/tests/test_background_service_probe.sh`
- `/bin/sh scripts/tests/test_background_service_settings.sh`
- `/bin/sh scripts/tests/test_background_service_wrappers.sh`
- `/bin/sh scripts/tests/test_background_service_ui_source.sh`
- `/bin/sh scripts/tests/test_session_dashboard_ui_source.sh`
- Swift tests cover catalog safety, exact state persistence, settings decoding, worker identity validation, dynamic resume, stale recovery, and dashboard classification.
- Package source checks require all background-service runtime scripts and both support libraries, executable in the app bundle, while excluding probe-output fixtures.
- Mutation source scans reject `killall`, SIGKILL, `launchctl disable`, `launchctl bootout`, LaunchAgent deletion, and protected-service names outside the protected policy/tests/docs.

## Background Service Suppression Catalina Checks

- Verify the supported catalog against Catalina 10.15.7 build 19H15 and the requesting console UID.
- Confirm Siri/Speech and iCloud Drive report **Unsupported** and are not mutated.
- Capture exact update preference presence, type, and values before ON; confirm exact restoration after OFF and Emergency Restore.
- Confirm each stopped process matches launch label, user UID, executable path, PID, and process start identity.
- Confirm only workers running before suppression and confirmed stopped by CatalinaPerformance are restarted.
- Open each associated app and verify session-long dynamic resume.
- Verify a five-second respawn check never re-suppresses a category after user resume.
- Verify stale-session recovery and unresolved root-setting reporting after force-quit/relaunch.
- Verify Safari password autofill, Keychain Access, AirDrop, Wi-Fi/DNS, push notifications, diagnostics/crash reporting, Finder, Dock, audio, and accessibility remain functional.
- Run alternating OFF/ON measurement sessions and document idle/unsupported targets without making unconditional performance claims.

## App Priority Automated Checks

- `/bin/sh scripts/tests/test_app_priority_wrappers.sh`
- `/bin/sh scripts/tests/test_app_priority_ui_source.sh`
- `cd app/CatalinaPerformance && swift test`
- `swift build --product CatalinaPerformance`
- `swift build --product CatalinaPerformancePriorityAgent`
- Selection files are atomic, owned by the requesting user, mode `0600`, non-symlinked, and validated against the current console user.
- Process-family tests cover recursive descendants, detached in-bundle helpers, other-user/root exclusions, PID reuse, and relaunch reacquisition.
- Monitor tests cover initial nice `-5`, two-second rescans, exact restoration, exited processes, and pending restoration failures.
- Wrapper tests cover disabled selection, validation failure, start rollback, OFF continuation, and Emergency Restore continuation.
- Source contracts confirm wrapper filenames, explicit state, selection, and priority-agent environment wiring, configuration locking, and packaged resources.

## App Priority Catalina Checks

- A saved stable-Firefox selection canonicalizes to `org.mozilla.firefox` and `/Applications/Firefox.app/Contents/MacOS/firefox`.
- Stable Firefox uses at most three nice `-1` targets: canonical parent/UI, one verified GPU helper, and one positive-activity content-style process.
- Idle preallocated, socket, RDD/data-decoder, utility, audio, crash-helper, outside-bundle, and unverifiable Firefox processes retain their original nice values.
- The content target wins by positive cumulative CPU-time delta for two consecutive complete scans before initial selection or switching.
- The old content target returns to its exact original value before a replacement is changed; failed old restoration blocks replacement mutation.
- Dashboard **Tracked Firefox Processes** can exceed **Processes Actually Boosted**, and reported parent/GPU/content PIDs match `ps` and `about:processes`.
- Firefox quit/relaunch while ON reacquires new exact identities and resets content CPU baselines.
- Firefox Developer Edition, Nightly, and other known browsers remain main-process-only.
- A non-browser sustained workload uses the verified same-user family policy at nice `-5`.
- Terminal same-user child commands may be included; root-owned `sudo` children are excluded.
- ON requests authorization once; OFF retains its normal authorization flow.
- Cancelled ON authorization triggers user-level rollback and leaves no monitor.
- A saved absent app reports Waiting and is acquired after launch.
- App Priority configuration controls are locked while ON.
- Foreground close-list conflicts are refused in both configuration directions.
- Normal OFF and Emergency Restore stop switching and restore valid outstanding records while core restoration continues after individual priority failures.
- Reboot preserves selection but does not restart monitoring or reapply any priority policy.
- A session with App Priority disabled reports **Not configured**, even when an older restored status file exists.
- At least five OFF and five focused-ON Firefox trials are run in alternating order with the same profile, query, starting tabs, completion criterion, elapsed-time record, and subjective note. One run is not accepted as performance evidence.
- Documentation and results do not claim improved browsing from correct targeting or CPU percentage; App Priority cannot improve network latency.

## WindowServer / GPU Pressure Automated Checks

- `/bin/sh scripts/tests/test_windowserver_pressure_source.sh`
- `/bin/sh scripts/tests/test_session_dashboard_ui_source.sh`
- `cd app/CatalinaPerformance && swift test`
- `swift build --product CatalinaPerformance`
- `swift build --product CatalinaPerformancePriorityAgent`
- WindowServer discovery requires one exact `WindowServer` process with a verified executable path ending in `/WindowServer`.
- CPU usage is calculated from cumulative process CPU-time deltas over elapsed wall-clock time; `ps %cpu` is not used.
- PID/start-identity replacement, ambiguous discovery, invalid intervals, decreasing counters, and resource-read failure produce **Unavailable** and require a fresh baseline.
- CPU values above `100%` are retained rather than clamped.
- The pre-ON baseline retains exactly three raw readings and computes baseline average/peak only from valid calculated CPU percentages.
- Pressure tests cover exact 15%/30% boundaries, +8/+12 percentage-point relative thresholds, three-value rolling averages, and two consecutive High candidates.
- Missing or unavailable readings never enter numeric averages as `0%`.
- Old schema-1 active and completed dashboard JSON without WindowServer fields continues to decode normally.
- Completed WindowServer reports remain below the existing 1 MiB dashboard-report limit.
- Source scans reject WindowServer kill, signal, priority, service-unload, defaults-write, and authorization paths.

## WindowServer / GPU Pressure Catalina Checks

- Follow `docs/WINDOWSERVER_GPU_PRESSURE_RUNTIME_CHECKLIST.md` on macOS Catalina 10.15.7.
- Confirm visible preparation progresses through `Measuring graphics baseline… 1/3`, `2/3`, and `3/3` before Performance Mode activation continues.
- Confirm WindowServer telemetry failure does not block ON, OFF, Emergency Restore, or app shutdown.
- Confirm active WindowServer readings update on the existing two-second Session Dashboard cadence without a second repeating timer.
- Confirm one transient Mission Control/window-animation spike does not immediately become sustained **High** pressure.
- Confirm the completed dashboard retains baseline, active, pre-restore, post-restore, maximum-pressure, and time-in-state data when available.
- Confirm the **Graphics / WindowServer** advisory remains diagnostic and causal-neutral; do not infer that Visual Performance caused a before/after change.
- Confirm no resolution, scaling, refresh-rate, display-profile, wallpaper, desktop-icon, Quartz-debug, private graphics-driver, WindowServer, Finder, Dock, or SystemUIServer mutation is introduced.

## Memory Pressure / Swap Management Capability Checks

- `/bin/sh scripts/tests/test_memory_vm_probe_source.sh`
- `/bin/sh scripts/tests/test_memory_taskpolicy_calibration_source.sh`
- `/bin/sh scripts/tests/test_catalina_process_support_source.sh`
- `cd app/CatalinaPerformance && swift test --filter MemoryTelemetryModelsTests`
- Confirm `CPVMMemoryInfo.availabilityMask` distinguishes unsupported counters from supported counters whose current value is zero.
- Confirm `cp_read_vm_memory_info` is implemented by exactly one C translation unit; duplicate definitions must fail the process-support source contract before linking.
- Confirm counter rollback/reset produces an unavailable interval rather than `0` activity.
- Confirm VM sampling remains on the existing two-second Performance Session cadence; no second VM timer is introduced.
- Confirm the capability probe is read-only: no `sudo`, `purge`, `sysctl -w`, defaults mutation, process termination, service unloading, or swap-file mutation.
- Target-Mac rebuild gate on Catalina 10.15.7 build 19H15 passed on 2026-08-07 after removing the duplicate VM C implementation. Both source contracts passed and all eight focused Memory Core/Agent test groups completed with zero failures; existing unrelated XCTest compiler warnings remained warning-only.

## Memory Pressure / Swap Management Session Integration Checks

- `cd app/CatalinaPerformance && swift test --filter MemoryManagementCoordinatorTests`
- `cd app/CatalinaPerformance && swift test --filter MemorySessionMetricIntegrationTests`
- `cd app/CatalinaPerformance && swift build --product CatalinaPerformanceMemoryAgent`
- `cd app/CatalinaPerformance && swift build --product CatalinaPerformance`
- Confirm old `SessionMetricSnapshot` JSON without `memoryManagement` still decodes.
- Confirm VM telemetry is captured only as part of the existing session sample; no second timer is introduced.
- Confirm High requires three consecutive candidates and Critical requires two.
- Confirm a workload must remain background for three samples and exceed `max(256 MiB, 5% physical RAM)` before admission.
- Confirm foreground and App Priority families are removed from desired state immediately.
- Confirm unavailable VM/process telemetry removes active desired families conservatively rather than fabricating healthy zero values.
- Confirm desired-state generations increase monotonically and no process priority is written by the user-side coordinator.
- Confirm Background Service Suppression recheck can only revisit the existing approved catalog and cannot reverse `.resumedByUser`.

## Memory Pressure / Swap Management Catalina Evidence Gate

- On macOS Catalina 10.15.7, run: `/bin/sh scripts/memory_vm_probe.sh --output "$HOME/Desktop/catalina-10.15.7-memory-vm-probe.txt"`.
- Record `sw_vers`, `uname -a`, `hw.memsize`, `hw.pagesize`, `vm.swapusage`, `memory_pressure`, selected read-only `vm.*` values, and three `vm_stat` samples two seconds apart.
- Verify counter names and units against the native `host_statistics64` fields used by CatalinaPerformance.
- Verify compression, page-in/page-out, and swap-in/swap-out counters are monotonic during ordinary sampling or explicitly document resets/rollbacks.
- The target Catalina 10.15.7 installation reports `/usr/bin/taskpolicy` unavailable; keep `CatalinaMemoryCapabilities.current.taskPolicy == false` and report I/O policy as **Unsupported**.
- Do not substitute a private API, newer-macOS command, permanent helper, or undocumented I/O-priority mechanism for missing `taskpolicy` in 1.0.
- Exercise a controlled memory-heavy workload during final runtime validation before tightening any currently unapproved swap-growth/churn rate thresholds.
