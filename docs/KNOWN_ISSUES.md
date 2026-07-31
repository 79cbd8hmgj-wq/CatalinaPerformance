# Known Issues

This page tracks current limitations and development notes for CatalinaPerformance.

## macOS Catalina Toolchain Setup

- Older Catalina Macs may need the full Xcode application installed rather than Command Line Tools only.
- `xcrun` may fail to find `xctest` until the full Xcode installation is selected with Xcode's settings or `xcode-select`.

## GUI Limitations

- GUI script output display was previously blank before Patch H. Current manual GUI testing should still verify that script output appears after **Refresh Status**, **Run Performance ON**, **Run Performance OFF**, and **Emergency Restore**.
- GUI sudo/admin handling may still need improvement. Some script actions can require administrator authorization, and the GUI may not yet provide the final intended authorization flow.

## Feature Gaps

- App Priority now uses a temporary privileged agent while Performance Mode is ON. It is intentionally limited to one remembered app at nice `-5`, validates full process identity before restoration, and does not install a persistent helper. Its practical effect is modest unless CPU contention exists, and the full AppKit/authorization/process-lifecycle matrix still requires testing on macOS Catalina.
- Thermal / Fan monitoring is read-only. CPU temperature and fan RPM may not be available without third-party tools, privileged `powermetrics` sampling, or SMC access, so the built-in report can show unavailable warnings on some Macs.
- Fan control is intentionally not implemented yet; aggressive fan behavior, max-fan mode, custom fan curves, and SMC write access remain disabled placeholders.
- Most Advanced options are placeholder-only; only the existing Background Services pause preferences and Power Behavior sleep/display preferences are script-readable via `~/Library/Application Support/CatalinaPerformance/advanced_preferences.env`.
- Power Behavior placeholders for disk sleep, Power Nap, and keeping network awake are not implemented.

## Safety Boundaries

CatalinaPerformance should continue to avoid SIP changes, automatic cache deletion, permanent service disablement, launch daemon changes, undervolting, MSR changes, kext changes, and other irreversible or unsafe system modifications.


## App Priority Limitations

- Only one application can be configured at a time.
- Main and verified same-user helper processes are checked every two seconds; a helper can run at normal priority briefly before discovery.
- Processes that exit need no restoration. Reused or identity-mismatched PIDs are skipped rather than risk changing an unrelated process.
- Root-owned children, critical macOS processes, and unverifiable helpers are excluded.
- A saved application that is absent remains in a waiting state until it launches.
- The selection is remembered after reboot, but the priority monitor does not restart and nice `-5` is not reapplied. Broader Performance Mode recovery state may still require OFF or Emergency Restore.
- The session-scoped agent is not a persistent privileged helper, daemon, or login item.

## Foreground Performance Session Limitations

- The feature is opt-in and disabled by default.
- Selected applications receive normal quit requests only. Save dialogs, unsaved work, or an application's refusal can prevent it from closing; CatalinaPerformance never force-quits it.
- Only applications confirmed closed by CatalinaPerformance are eligible for automatic relaunch. Applications already running at restore time are skipped rather than duplicated.
- Relaunch restores the application, not necessarily identical windows, tabs, document positions, or unsaved state.
- Terminal and iTerm/iTerm2 are intentionally and permanently excluded in the first implementation to avoid interrupting builds, scripts, or unrelated commands.
- Finder and Dock are not killed or signaled. Their temporary animation preferences may take effect only after those components naturally restart.
- Application and UI-preference restore failures remain recorded under `~/Library/Application Support/CatalinaPerformance/foreground_session/runtime/` for retry.
- The current portable test environment verifies pure Swift logic and fixture-driven shell behavior. The full AppKit interaction and LaunchServices behavior still require manual testing on macOS Catalina with Xcode 12.4.
