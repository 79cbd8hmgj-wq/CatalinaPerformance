# Known Issues

This page tracks current limitations and development notes for CatalinaPerformance.

## macOS Catalina Toolchain Setup

- Older Catalina Macs may need the full Xcode application installed rather than Command Line Tools only.
- `xcrun` may fail to find `xctest` until the full Xcode installation is selected with Xcode's settings or `xcode-select`.

## GUI Limitations

- GUI script output display was previously blank before Patch H. Current manual GUI testing should still verify that script output appears after **Refresh Status**, **Run Performance ON**, **Run Performance OFF**, and **Emergency Restore**.
- GUI sudo/admin handling may still need improvement. Some script actions can require administrator authorization, and the GUI may not yet provide the final intended authorization flow.

## Feature Gaps

- App Priority uses a temporary privileged agent while Performance Mode is ON. Stable Firefox uses an experimental focused parent/GPU/content policy at nice `-1`; other known browsers remain main-process-only, and non-browser sustained workloads use verified-family nice `-5`. It validates full process identity before restoration and does not install a persistent helper. Correct targeting does not guarantee faster browsing.
- Thermal / Fan monitoring is read-only. CPU temperature and fan RPM may not be available without third-party tools, privileged `powermetrics` sampling, or SMC access, so the built-in report can show unavailable warnings on some Macs.
- Fan control is intentionally not implemented yet; aggressive fan behavior, max-fan mode, custom fan curves, and SMC write access remain disabled placeholders.
- Most Advanced options are placeholder-only; only the existing Background Services pause preferences and Power Behavior sleep/display preferences are script-readable via `~/Library/Application Support/CatalinaPerformance/advanced_preferences.env`.
- Power Behavior placeholders for disk sleep, Power Nap, and keeping network awake are not implemented.

## Safety Boundaries

CatalinaPerformance should continue to avoid SIP changes, automatic cache deletion, permanent service disablement, launch daemon changes, undervolting, MSR changes, kext changes, and other irreversible or unsafe system modifications.


## App Priority Limitations

- Only one application can be configured at a time.
- Stable Firefox alone uses the experimental focused policy: parent/UI, GPU helper, and one activity-selected content-style process at nice `-1`, with no more than three simultaneous restore obligations.
- Firefox Developer Edition, Nightly, and other known browsers remain main-process-only. Non-browser sustained workloads retain the verified-family nice `-5` policy.
- Firefox process layout and argument roles may change between releases. Extension, about-page, preallocated, and visible web content can share content-style characteristics.
- CPU activity is an inference, not proof that the selected content-style PID owns the visible tab. CatalinaPerformance does not inspect URLs or tab titles.
- The two-second monitor requires two consecutive positive-delta wins before content selection or switching, so a new page can run at normal priority briefly.
- App Priority cannot improve network latency. A technically correct policy may still make browsing slower and should be disabled if repeated Catalina trials show regression.
- Combined Firefox CPU can exceed 100% because aggregate activity spans multiple processes and CPU cores.
- Processes that exit need no restoration. Reused or identity-mismatched PIDs are skipped rather than risk changing an unrelated process.
- Root-owned children, critical macOS processes, and unverifiable helpers are excluded.
- A saved application that is absent remains in a waiting state until it launches.
- The selection is remembered after reboot, but the priority monitor does not restart and no priority policy is reapplied. Broader Performance Mode recovery state may still require OFF or Emergency Restore.
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
## Background Service Suppression Limitations

- The target catalog is intentionally limited to identities verified on macOS Catalina 10.15.7 build 19H15. It does not infer targets from display names, substrings, or another macOS release.
- Siri/Dictation/speech and iCloud Drive are currently reported as **Unsupported** because a sufficiently isolated, reversible target was not proven. The iCloud Drive checkbox remains disabled on this catalog.
- Supported user workers may relaunch on demand. CatalinaPerformance checks every five seconds while a category remains eligible; opening the associated application exempts that category for the rest of the session.
- Stopping a verified background worker may delay Photos, Mail, Messages, or FaceTime background activity until the app is opened or Performance Mode is turned OFF.
- Root-owned update preferences require the existing explicit administrator flow. Startup recovery restores user-owned workers but must not generate an unsolicited password prompt for unresolved root settings.
- A service that was already idle, absent, or disabled may provide no measurable performance improvement. Dashboard state proves the requested action and restoration evidence, not causality or speedup.
- The catalog must be removed or narrowed immediately if Catalina testing shows overlap with Keychain, Safari passwords, AirDrop, networking, push notifications, diagnostics, crash reporting, Finder, Dock, audio, or accessibility.
