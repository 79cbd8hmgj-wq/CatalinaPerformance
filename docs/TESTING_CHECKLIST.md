# CatalinaPerformance Testing Checklist

## Baseline safety checks

For each system tweak:

- Confirm the change is scoped to the documented subsystem.
- Confirm state is captured before mutation whenever restoration is required.
- Confirm verification follows each mutation.
- Confirm failed restoration state is preserved for retry rather than discarded.
- Confirm Emergency Restore covers every subsystem that can mutate persistent or session state.
- Confirm no code path modifies SIP.
- Confirm no code path automatically deletes caches.

## Foreground Performance Session Automated Checks

- `/bin/sh -n scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh`
- `/bin/sh scripts/tests/test_foreground_session.sh all`
- `/bin/sh scripts/tests/test_advanced_layout_source.sh`
- `/bin/sh scripts/tests/test_app_priority_wrappers.sh`
- `/bin/sh scripts/tests/test_app_priority_ui_source.sh`
- `cd app/CatalinaPerformance && swift test`
- Confirm foreground/session wrapper scripts do not use `kill -9`, `killall`, `pkill`, arbitrary PID mutation, permanent LaunchAgents/LaunchDaemons, or unrelated defaults writes.
- Confirm no foreground-session or UI-responsiveness script requests administrator authorization.
- Verify Performance ON/OFF and Emergency Restore authorization behavior is unchanged.

## Background Service Suppression Automated Checks

- `/bin/sh scripts/tests/test_background_service_probe.sh`
- `/bin/sh scripts/tests/test_background_service_suppression_source.sh`
- `/bin/sh scripts/tests/test_background_service_suppression_runtime.sh`
- Confirm the five-second monitor only re-scans the approved category catalog.
- Confirm `.resumedByUser` categories are not automatically re-suppressed.
- Confirm AirDrop, networking, audio, Bluetooth, Keychain/password, and diagnostics infrastructure remain protected.
- Confirm Background Service Suppression restore failures remain visible and retryable.

## Visual Performance Automated Checks

- `/bin/sh scripts/tests/test_visual_performance_probe_source.sh`
- `/bin/sh scripts/tests/test_visual_performance_source.sh`
- `/bin/sh scripts/tests/test_visual_performance_runtime.sh`
- Confirm compare-before-restore preserves manual changes made while Performance Mode is active.
- Confirm originally absent defaults keys are deleted only when they still contain the app-applied value.
- Confirm restore failures are isolated per setting and retained for retry.
- Confirm no logout, Finder restart, Dock restart, or WindowServer restart is required.

## WindowServer / Graphics Pressure Automated Checks

- `/bin/sh scripts/tests/test_windowserver_pressure_source.sh`
- `cd app/CatalinaPerformance && swift test --filter WindowServer`
- Confirm WindowServer collection is read-only and does not use sudo, task_for_pid, private graphics mutation, Quartz debug flags, display changes, or process priority mutation.
- Confirm WindowServer identity requires the system SkyLight WindowServer executable path and PPID 1.
- Confirm the production fallback uses cumulative process TIME rather than `%CPU`.
- Confirm unavailable or failed WindowServer reads remain unavailable rather than being treated as zero.
- Confirm rolling averages use only valid samples and CPU values above 100% remain valid on multicore hardware.
- Confirm High requires the documented consecutive-candidate confirmation.
- Confirm the completed dashboard retains baseline, active, pre-restore, post-restore, maximum-pressure, and time-in-state data when available.
- Confirm the **Graphics / WindowServer** advisory remains diagnostic and causal-neutral; do not infer that Visual Performance caused a before/after change.
- Confirm no resolution, scaling, refresh-rate, display-profile, wallpaper, desktop-icon, Quartz-debug, private graphics-driver, WindowServer, Finder, Dock, or SystemUIServer mutation is introduced.

## Memory Pressure / Swap Management Capability Checks

- `/bin/sh scripts/tests/test_memory_vm_probe_source.sh`
- `/bin/sh scripts/tests/test_memory_taskpolicy_calibration_source.sh`
- `/bin/sh scripts/tests/test_catalina_process_support_source.sh`
- `cd app/CatalinaPerformance && swift test --filter MemoryTelemetryModelsTests`
- `cd app/CatalinaPerformance && swift test --filter CatalinaMemoryCapabilitiesTests`
- `cd app/CatalinaPerformance && swift test --filter MemoryPressureClassifierTests`
- `cd app/CatalinaPerformance && swift test --filter MemoryProcessFamilyAnalyzerTests`
- `cd app/CatalinaPerformance && swift test --filter MemoryDesiredStateStoreTests`
- `cd app/CatalinaPerformance && swift test --filter MemoryAgentStateStoreTests`
- `cd app/CatalinaPerformance && swift test --filter MemoryInterventionControllerTests`
- `cd app/CatalinaPerformance && swift test --filter MemoryAgentServiceTests`
- Confirm `CPVMMemoryInfo.availabilityMask` distinguishes unsupported counters from supported counters whose current value is zero.
- Confirm counter rollback/reset produces an unavailable interval rather than `0` activity.
- Confirm VM sampling remains on the existing two-second Performance Session cadence; no second VM timer is introduced.
- Confirm the capability probe is read-only: no `sudo`, `purge`, `sysctl -w`, defaults mutation, process termination, service unloading, or swap-file mutation.
- Catalina 10.15.7 build 19H15 rebuild gate on 2026-08-07: duplicate `cp_read_vm_memory_info` definition removed; both source contracts passed and all eight focused Memory Core/Agent test groups completed with zero failures. Existing unrelated XCTest compiler warnings remained warning-only.
- `/usr/bin/taskpolicy` is absent on the target Catalina installation. Memory Pressure & Swap Management 1.0 therefore reports I/O policy as Unsupported and uses the approved reversible nice `+5` policy only.

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
- Exercise a controlled memory-heavy workload and capture a second probe so rate thresholds can be based on observed Catalina behavior rather than guessed values.
- Do not enable unreviewed production rate thresholds or broader automatic memory intervention from evidence that has not been reviewed and committed.
