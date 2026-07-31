# CatalinaPerformance

CatalinaPerformance is an early-stage macOS utility concept for older Intel Macs running macOS Catalina. The long-term goal is a simple, reversible **Performance Mode** toggle that temporarily reduces background activity and surfaces basic system health signals while the Mac is plugged in.

This repository is intentionally starting small. The first patches document the product goals, safety rules, planned features, and testing checklist before any system-changing code is added.

## Target Platform

- macOS Catalina 10.15
- Older Intel-based Macs
- User-controlled, reversible performance adjustments

## Core Concept

The app will eventually provide one main switch:

- **Performance Mode ON**: apply temporary, reversible settings intended to reduce background work and keep the Mac awake while on AC power.
- **Performance Mode OFF**: restore every setting changed by the app to its previous state.

Planned status indicators include:

- CPU temperature
- Fan speed
- RAM pressure
- Swap usage
- Disk space
- Whether sleep, Time Machine, Spotlight indexing, and thermal behavior adjustments are active

## Non-Goals for Early Patches

This repository includes a local macOS GUI shell and a reversible, user-level Foreground Performance Session. It does **not** implement a privileged helper, fan control, launch daemon toggles, cache cleaning, undervolting, MSR changes, kext changes, SIP changes, or irreversible system tweaks. Future behavior should continue to be built in small, reviewable patches with matching restore paths.

## Safety Principles

CatalinaPerformance must be conservative by default:

- Keep all changes reversible.
- Every system tweak must have a matching restore path.
- Do not modify System Integrity Protection (SIP).
- Do not delete caches automatically.
- Do not disable services permanently.
- Prefer temporary sessions and explicit user consent over persistent changes.

See [docs/SAFETY_RULES.md](docs/SAFETY_RULES.md) for the detailed safety contract. See [docs/GUI_TESTING.md](docs/GUI_TESTING.md) for the current manual GUI test flow and [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) for current limitations.

## Repository Layout

```text
.
├── README.md
├── AGENTS.md
├── docs/
│   ├── APP_CONCEPT.md
│   ├── FEATURE_PLAN.md
│   ├── GUI_TESTING.md
│   ├── KNOWN_ISSUES.md
│   ├── SAFETY_RULES.md
│   └── TESTING_CHECKLIST.md
├── app/
│   └── CatalinaPerformance/
│       ├── Package.swift
│       └── Sources/CatalinaPerformance/main.swift
└── scripts/
    ├── build_gui.sh
    ├── package_app.sh
    ├── emergency_restore.sh
    ├── app_priority_report.sh
    ├── memory_storage_report.sh
    ├── performance_off.sh
    ├── performance_on.sh
    ├── run_gui.sh
    ├── status_report.sh
    ├── thermal_fan_report.sh
    └── test_performance_cycle.sh
```

## Current Status

Initial documentation, reversible Performance Mode scripts, read-only health reports, a local AppKit GUI, a development `.app` packaging helper, the opt-in Foreground Performance Session, the session-scoped App Priority feature, and a read-only Performance Session Dashboard are present. No persistent privileged helper or fan-control behavior is installed.

## Local GUI Development

A minimal macOS GUI shell now lives in `app/CatalinaPerformance`. It is a Swift Package Manager AppKit executable targeting macOS Catalina 10.15 and older Intel Macs.

The GUI is intentionally thin:

- It displays the CatalinaPerformance app name, a Performance Mode ON/OFF switch, a small detected-state label, a success/failure status area, script output, and buttons for status refresh, Performance ON, Performance OFF, Emergency Restore, Advanced, and View Session Dashboard.
- The Advanced window is a scrollable configuration UI organized into Background Services, Power Behavior, Foreground Performance Session, App Priority, Memory / Storage, Thermal / Fan, Experimental, and Emergency / Restore sections.
- Most Advanced controls are disabled placeholders clearly labeled `Not implemented yet`; the selectable Background Services, Power Behavior, and read-only Memory / Storage checkboxes write script-readable preferences to `~/Library/Application Support/CatalinaPerformance/advanced_preferences.env`. The Performance Mode scripts read only the system-changing Background Services and Power Behavior preferences; Memory / Storage preferences control only the manual read-only report. Missing or invalid preferences default to enabled for current-behavior compatibility. App Priority is an optional temporary process-priority feature, while Thermal / Fan remains read-only.
- The Power Behavior section can configure the existing `pmset` behavior: **Prevent plugged-in system sleep while Performance Mode is ON** and **Prevent display sleep while Performance Mode is ON** both default to enabled. If either option is disabled, `performance_on.sh` still records the current `pmset` state but skips that specific `pmset -c` change and logs the skip; `performance_off.sh` restores only the selected actions that were recorded.
- Power Behavior placeholders for preventing disk sleep, disabling Power Nap, and keeping network awake remain visibly disabled and labeled `Not implemented yet`.
- The App Priority section remembers one selected application. While Performance Mode is ON, a session-scoped privileged agent sets the verified main process and verified same-user helper/child processes to nice `-5`, checks every two seconds for new helpers, and reacquires a relaunched instance. It records PID, ownership, executable path, process start time, and original nice value before each change, then restores only identities that still match on OFF or Emergency Restore. The **Run App Priority Report** button remains read-only and prints a bounded process list for verification. No persistent helper, daemon, login item, or service is installed.
- The Memory / Storage section provides enabled-by-default read-only options for showing swap usage warnings, low disk space warnings, a memory pressure summary, and top memory-heavy processes. The **Run Memory / Storage Check** button calls `scripts/memory_storage_report.sh`, prints results in the main output area, uses no sudo, and does not delete files, clear caches, tune memory, or change settings.
- The Thermal / Fan section provides a read-only **Run Thermal / Fan Check** button that calls `scripts/thermal_fan_report.sh`. The report uses safe built-in macOS status commands such as `pmset -g therm` when available, identifies thermal constraints from parsed percentage-style `CPU_Speed_Limit`, `CPU_Scheduler_Limit`, and `GPU_Speed_Limit` values instead of status-note wording. It displays `CPU_Available_CPUs` as informational CPU-count data and prints clear unavailable warnings when CPU temperature or fan RPM cannot be obtained without privileged, SMC, or third-party access. It does not use sudo, control fans, write SMC values, load kexts, modify SIP, change kernel behavior, or alter system settings.
- Memory / Storage warning thresholds are intentionally conservative and documented in the GUI and script output: swap usage above 1024 MB, disk free space below 10% or below 10 GB, and memory pressure output containing warn/critical states. Top disk-heavy folder scanning remains a disabled placeholder for a future optional read-only manual scan.
- Cache cleanup tools, browser cache cleanup, and automatic cleanup remain disabled and labeled **Not implemented yet — future manual-only feature** or discouraged; CatalinaPerformance does not perform automatic cleanup.
- It calls the existing scripts in `scripts/` instead of duplicating system-changing logic.
- It detects Performance Mode by checking `~/Library/Application Support/CatalinaPerformance/system_state/performance_mode_on`, then disables Performance ON while the marker exists and disables Performance OFF while the marker is absent. Emergency Restore remains available.
- It prints the exact `/bin/sh ...` command for each script, captures stdout and stderr in the scrollable output area, auto-scrolls after each run, and updates the status label with success or failure.
- It does not implement fan control, cache cleaning, SIP changes, launch daemon toggles, undervolting, MSR changes, kext loading, or experimental features.
- It shows warning confirmations before running Performance ON or Emergency Restore.


### App Priority Session

The **Advanced → App Priority** feature is optional and defaults to OFF. It remembers one application by display name, bundle identifier, application bundle path, and executable path. The same application cannot simultaneously be selected for the Foreground close list.

When Performance Mode turns ON and App Priority is enabled:

1. The normal administrator authorization starts a temporary, session-scoped priority agent; no persistent helper is installed.
2. The agent validates the selection file and current console-user ownership.
3. It identifies the selected application's main process plus verified same-user descendants and in-bundle helpers.
4. It records each process identity and exact original nice value, then applies nice `-5` only when that would be a boost.
5. Every two seconds it discovers new helpers and reacquires a verified relaunched application instance.

Performance Mode OFF and Emergency Restore cooperatively stop monitoring and restore exact recorded nice values only when PID, UID, executable path, and process start time still match. Exited or PID-reused processes are never mutated. Root-owned processes and critical system processes are excluded. The selected application remains remembered after launch or reboot, but a reboot resets process priority naturally and does not restart the priority monitor or reapply nice `-5`. If broader Performance Mode state remains recorded, use OFF or Emergency Restore to complete its normal recovery path.

The expected benefit is modest and appears primarily when the CPU is contended. App Priority does not increase CPU frequency, GPU performance, RAM, fan speed, or hardware limits, and it does not modify SIP, install a daemon, or kill an application.

### Performance Session Dashboard

The **View Session Dashboard** button opens a dedicated read-only window. Dashboard collection is tied to the existing Performance Mode lifecycle but does not add a script, privileged helper, administrator prompt, or system mutation. Closing the dashboard window does not stop collection.

A successful Performance Mode ON cycle records a baseline before the existing ON sequence, begins live collection only after that sequence succeeds, and updates normal metrics every two seconds. Thermal scheduler and speed limits are refreshed at approximately ten-second intervals. Performance Mode OFF or Emergency Restore captures a bounded pre-restore snapshot, runs the unchanged restore path, captures a post-restore snapshot, and produces the most recent completed-session summary. A failed ON cycle discards its incomplete dashboard record. A failed restore that leaves Performance Mode active resumes the same dashboard session with a warning.

The dashboard reports:

- system CPU use;
- memory-pressure state and physical memory use;
- swap use and startup-volume free space;
- `CPU_Scheduler_Limit` and `CPU_Speed_Limit` when `pmset -g therm` provides them;
- selected App Priority application CPU, resident memory, verified process count, and confirmed nice `-5` count; and
- evidence for Spotlight, Time Machine, power settings, UI responsiveness, temporary application closing, and App Priority activation/restoration.

Selected-app values include the same verified main process and helper family used by App Priority. Unsupported or failed measurements display **Unavailable** rather than zero. The initial CPU baseline may be unavailable until two host counter readings exist. `CPU_Available_CPUs` is never treated as a percentage. CPU temperature and fan RPM remain unavailable because the dashboard does not add an SMC or third-party sensor module.

The dashboard presents observations rather than a performance score. Higher CPU use is not automatically labeled an improvement, and nice `-5` confirmation does not claim that a workload completed faster. There is no cloud telemetry, raw two-second history export, historical browser, or privileged monitoring prompt.

Only the active session and the most recent completed session are retained:

```text
~/Library/Application Support/CatalinaPerformance/session_dashboard/
├── active-session.json
└── last-completed-session.json
```

Writes are atomic and bounded. Raw two-second samples are reduced to baseline, latest, average, peak, count, availability, and error summaries. If CatalinaPerformance relaunches while Performance Mode remains ON, it resumes the original session and records a monitoring gap. If an active dashboard record exists but Performance Mode is no longer active, it becomes an **Interrupted** report without changing system settings. Invalid records are moved to bounded diagnostic backups and shown as non-blocking warnings.

### Foreground Performance Session

The **Advanced → Foreground Performance Session** feature is opt-in and defaults to OFF. It is a user-level responsiveness feature, not an overclock or process-priority tool.

When enabled for Performance Mode ON, CatalinaPerformance:

1. Reads explicitly selected GUI applications by bundle identifier.
2. Writes recoverable runtime state under `~/Library/Application Support/CatalinaPerformance/foreground_session/runtime/` before changing anything.
3. Sends normal application quit requests and waits for bounded confirmation.
4. Marks an application eligible for relaunch only after CatalinaPerformance confirms it exited.
5. Saves and applies the enabled Finder, Dock, and general window-animation preferences.
6. Runs the existing administrator-authorized Performance ON script.

Performance Mode OFF restores the system-level Performance Mode first, then restores exact recorded UI preference values and relaunches only applications confirmed closed by CatalinaPerformance. A failed relaunch remains recorded for retry.

Permanent exclusions include CatalinaPerformance, Terminal, iTerm/iTerm2, Finder, Dock, SystemUIServer, WindowServer, and loginwindow. The implementation never uses force quit, `kill`, `killall`, saved PIDs, `renice`, or `sudo` for foreground-session actions. Applications may refuse to quit or display save dialogs. Relaunching an application does not guarantee restoration of identical windows or unsaved document state.

State and preferences live at:

```text
~/Library/Application Support/CatalinaPerformance/foreground_session/
├── preferences.env
├── runtime/
│   ├── session.env
│   ├── applications.tsv
│   └── ui_preferences.tsv
└── logs/
    ├── apply.log
    └── restore.log
```

Portable checks:

```sh
/bin/sh scripts/tests/test_foreground_session.sh all
cd app/CatalinaPerformance
swift test
swift build
```

Finder and Dock animation preferences are not applied by killing or signaling those processes. Some changes may therefore become visible only after Finder or Dock naturally restarts.

### Building the GUI

Use the local build helper from anywhere inside or outside the repository:

```sh
/path/to/Catilinaperformance-/scripts/build_gui.sh
```

The helper only verifies the local developer tools and runs `swift build` in `app/CatalinaPerformance`; it does not change system settings or apply Performance Mode. It checks that an Xcode developer directory is selected, that `xcrun` can locate `xctest`, and that `swift` is available before building the package.

### Running the GUI from Terminal

Use the local run helper from anywhere inside or outside the repository:

```sh
/path/to/Catilinaperformance-/scripts/run_gui.sh
```

The helper sets `CATALINA_PERFORMANCE_SCRIPTS_DIR` to this checkout's `scripts/` directory, prints the exact command it is about to run, then launches the Swift package with `swift run CatalinaPerformance`. The GUI still requires clear user intent before running any Performance Mode script.

You can also run the package manually from a macOS Catalina development machine with Xcode installed:

```sh
cd app/CatalinaPerformance
CATALINA_PERFORMANCE_SCRIPTS_DIR=/path/to/Catilinaperformance-/scripts swift run CatalinaPerformance
```

### Packaging the Local `.app`

Use the local packaging helper from anywhere inside or outside the repository:

```sh
/path/to/Catilinaperformance-/scripts/package_app.sh
```

The packaging helper verifies that full Xcode is selected with `xcode-select`, confirms `xcrun` can find `xctest`, confirms `swift` is available, checks that the required GUI and performance scripts exist, runs `swift build`, then creates a local app bundle at:

```text
build/CatalinaPerformance.app
```

The generated bundle contains a simple `Info.plist`, the built Swift GUI executable, and a local launcher in `Contents/MacOS/`. The launcher preserves `CATALINA_PERFORMANCE_SCRIPTS_DIR` if it is already set; otherwise, it sets that environment variable to this checkout's `scripts/` directory so the GUI can find `status_report.sh`, `performance_on.sh`, `performance_off.sh`, and `emergency_restore.sh`.

### Launching the Packaged `.app`

After packaging, launch the app from Terminal with:

```sh
open /path/to/Catilinaperformance-/build/CatalinaPerformance.app
```

You may also double-click `build/CatalinaPerformance.app` in Finder on the development Mac. The packaged app uses the same GUI and scripts as `scripts/run_gui.sh`; it does not install anything into `/Applications`, does not add a privileged helper, does not add code signing or notarization, and does not change performance behavior.

### Current `.app` Limitations

The packaged `.app` is for local development only:

- It is unsigned and not notarized.
- It is not installed into `/Applications` automatically.
- Runtime scripts and `CatalinaPerformancePriorityAgent` are copied into `Contents/Resources`; the repository checkout is not required after a successful package build.
- Advanced options include the existing reversible Background Services and Power Behavior choices, the opt-in App Priority session, Foreground Performance Session, the read-only Performance Session Dashboard, and manual read-only Memory / Storage and Thermal / Fan reporting. Most other controls remain disabled placeholders. There is no fan control, cache cleaning, browser cleanup, automatic cleanup, persistent launch daemon/helper installation, SIP modification, undervolting, MSR access, kext loading, or experimental CPU feature control.

### Xcode 12.4 and Catalina Notes

CatalinaPerformance targets macOS Catalina 10.15 and uses Swift Package Manager with AppKit. For the intended Catalina development environment, install Xcode 12.4 and open it at least once so macOS can finish installing required components. If multiple Xcode versions or only the command line tools are installed, select the full Xcode developer directory before building:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The helper scripts do not run `sudo`, do not change the selected developer directory, and do not alter SIP, caches, launch daemons, fan controls, or other system performance settings.

### xctest Troubleshooting

If `scripts/build_gui.sh` reports that `xcrun` cannot find `xctest`, the selected developer tools are usually incomplete or point at the command line tools instead of full Xcode. Check the selected path with:

```sh
xcode-select -p
xcrun -f xctest
```

On Catalina, resolve this by installing or repairing Xcode 12.4, opening Xcode once to complete setup, and selecting `/Applications/Xcode.app/Contents/Developer` with `xcode-select`. Re-run `scripts/build_gui.sh` after `xcrun -f xctest` prints a valid path.


### GUI Test Instructions

See [docs/GUI_TESTING.md](docs/GUI_TESTING.md) for the current manual GUI test flow. Use a macOS development machine for GUI behavior because the AppKit executable does not launch on non-macOS systems. To test the output and state handling safely during development:

1. Start from the package directory and point the GUI at the repository scripts if needed:

   ```sh
   cd app/CatalinaPerformance
   CATALINA_PERFORMANCE_SCRIPTS_DIR=/path/to/Catilinaperformance-/scripts swift run CatalinaPerformance
   ```

2. Click **Refresh Status** and confirm the output box shows the exact `/bin/sh .../status_report.sh` command followed by script stdout/stderr and an exit-status line.
3. With `.catalina_performance_state/performance_mode_on` absent, confirm the state label says **Performance Mode appears OFF**, **Run Performance OFF** is disabled, **Run Performance ON** is enabled, and **Emergency Restore** remains enabled.
4. Create or preserve the marker file only through the reviewed scripts when possible. After running **Run Performance ON**, confirm the GUI refreshes the switch and state label from `.catalina_performance_state/performance_mode_on`, disables **Run Performance ON**, and keeps output scrolled to the latest exit-status line.
5. After running **Run Performance OFF** or **Emergency Restore**, confirm the marker is removed, the switch and label show OFF, **Run Performance OFF** is disabled, and **Emergency Restore** remains enabled.
6. Open **Advanced** and confirm the panel shows planning sections for Background Services, Power Behavior, App Priority, Memory / Storage, Thermal / Fan, Experimental, and Emergency / Restore. Confirm disabled controls are labeled **Not implemented yet** or **Not implemented yet — disabled for safety**. Toggle the selectable Background Services, Power Behavior, and Memory / Storage preferences and confirm they save to `~/Library/Application Support/CatalinaPerformance/advanced_preferences.env` without running system-changing scripts immediately; only the Background Services and Power Behavior preferences affect the next Performance ON run.
7. In **Advanced → App Priority**, select one harmless app, enable the feature, and confirm the selection persists. The report button itself remains read-only. Use the dedicated App Priority Catalina matrix in `docs/GUI_TESTING.md` before relying on ON/OFF restoration.
8. In **Advanced > Memory / Storage**, click **Run Memory / Storage Check** and confirm the main output area shows `scripts/memory_storage_report.sh` output for the enabled read-only checks. Confirm cache cleanup, browser cache cleanup, automatic cleanup, and top disk-heavy folder scanning remain disabled placeholders and that no files are deleted.
9. In **Advanced > Thermal / Fan**, click **Run Thermal / Fan Check** and confirm the main output area shows `scripts/thermal_fan_report.sh` output without requesting sudo or changing fan, SMC, kernel, SIP, or system settings. Confirm Aggressive fan behavior, Max fans while Performance Mode is ON, and Custom fan curve remain disabled placeholders.
10. Repeat an ON/OFF cycle and verify each run reports a clear success or failure in the status label without adding fan control, cache cleaning, SIP changes, launch daemon controls, privileged helpers, or system-changing Advanced behavior.
11. Open **View Session Dashboard** while OFF, then run an ON/OFF cycle with a selected App Priority target. Verify the dashboard changes through Preparing, Active, Finalizing, and Last Completed Session; normal metrics update every two seconds; closing and reopening the dashboard does not reset the sample count; only one active and one completed report are retained; unsupported temperature and fan values show **Unavailable**; and no extra authorization prompt appears.

Future packaged `.app` work should keep the same app/script boundary: the GUI may collect user intent and display output, while reversible system behavior and restore paths remain in reviewed scripts.
