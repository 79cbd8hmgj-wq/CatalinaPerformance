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

- One TextEdit main process changes to `-5` on ON and returns to its original value on OFF.
- Firefox main/helpers change to `-5`; a newly created helper is detected within four seconds.
- Firefox quit/relaunch while ON is reacquired with a new verified identity.
- Terminal same-user child commands may be included; root-owned `sudo` children are excluded.
- ON requests authorization once; OFF retains its normal authorization flow.
- Cancelled ON authorization triggers user-level rollback and leaves no monitor.
- A saved absent app reports Waiting and is boosted after launch.
- App Priority configuration controls are locked while ON.
- Foreground close-list conflicts are refused in both configuration directions.
- Emergency Restore stops monitoring and restores valid outstanding records.
- Reboot preserves selection but does not restart monitoring or reapply nice `-5`; any broader Performance Mode recovery marker is handled through OFF or Emergency Restore.
