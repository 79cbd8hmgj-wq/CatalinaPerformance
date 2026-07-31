# Foreground Performance Session Design

## Summary

CatalinaPerformance will gain an optional **Foreground Performance Session** that reduces competing user-level workload while Performance Mode is active. The feature will gracefully close only explicitly selected GUI applications, temporarily reduce selected UI animations, and later restore both the applications and the exact prior UI preference values.

The feature is intended to improve responsiveness and sustained performance on older Intel Macs by freeing RAM, reducing background CPU and disk activity, and lowering avoidable thermal load. It does not overclock the CPU, alter process priority, force-quit software, control fans, or change SIP.

## Product Behavior

The feature lives in **Advanced → Foreground Performance Session** and is disabled by default.

When Performance Mode turns ON:

1. CatalinaPerformance validates that Foreground Performance Session preferences and runtime state storage are writable.
2. It identifies selected running applications by bundle identifier.
3. It writes pre-change runtime state.
4. It requests each selected application to quit normally.
5. It waits for each application to exit and records the actual result.
6. It applies enabled UI-responsiveness preferences after saving their exact prior state.
7. It runs the existing administrator-authorized `performance_on.sh` path.

When Performance Mode turns OFF:

1. CatalinaPerformance runs the existing administrator-authorized `performance_off.sh` path.
2. It restores the exact prior UI preference values.
3. It relaunches only applications that were running before the session and were confirmed closed by CatalinaPerformance.
4. It preserves unresolved restore state for retry and reports failures without hiding successful system restoration.

Manual Advanced controls will allow dry-run, apply, restore, state inspection, and application-list refresh without requiring a full Performance Mode cycle.

## Scope

### Included

- Listing eligible running GUI applications.
- Selection by durable bundle identifier.
- Graceful quit requests only.
- Verification that selected applications actually exited.
- Relaunch of only successfully closed applications.
- Reversible Finder, Dock, and general window-animation preference changes.
- Manual dry-run, apply, restore, and state-view controls.
- Integration with the existing centralized GUI script lock.
- Integration with the existing Performance ON/OFF flow.
- User-level logs and runtime state under Application Support.

### Excluded

- Force quit, `kill`, `killall`, or signal-based suspension.
- PID-based persistent identity.
- Process priority or `renice` behavior.
- Automatic application selection.
- Fan or SMC control.
- SIP changes.
- Turbo Boost control.
- Undervolting, MSR access, kext loading, or CPU power-limit modification.
- System launch daemon manipulation.
- Cache deletion.

## Permanent Application Exclusions

The following must never appear as selectable targets in the first implementation:

- CatalinaPerformance
- Terminal
- iTerm / iTerm2
- Finder
- Dock
- SystemUIServer
- WindowServer
- loginwindow

Applications without a reliable bundle identifier are also excluded. Terminal and iTerm remain excluded even when CatalinaPerformance was launched as a packaged app, because closing them can interrupt builds, scripts, or unrelated active commands.

## Architecture

The existing architecture remains intact: AppKit collects user intent and displays output; reviewed POSIX shell scripts own reversible behavior and state transitions.

### New scripts

- `scripts/foreground_session_list.sh`
  - Read-only.
  - Lists eligible running GUI applications with display name and bundle identifier.
  - Excludes protected applications and applications without a bundle identifier.

- `scripts/foreground_session_apply.sh`
  - User-level; no sudo.
  - Reads recognized selected bundle identifiers.
  - Writes runtime state before quit requests.
  - Requests graceful application termination.
  - Records which applications were running, requested to quit, confirmed closed, refused, or timed out.
  - Supports `--dry-run` and `--yes`.

- `scripts/foreground_session_restore.sh`
  - User-level; no sudo.
  - Reads valid runtime state.
  - Relaunches only applications confirmed closed by CatalinaPerformance.
  - Skips applications already running.
  - Preserves failed restore state for retry.
  - Supports `--dry-run` and `--yes`.

- `scripts/ui_responsiveness_apply.sh`
  - User-level; no sudo.
  - Saves exact prior preference existence and values before changes.
  - Applies only enabled animation reductions.
  - Supports `--dry-run`.

- `scripts/ui_responsiveness_restore.sh`
  - User-level; no sudo.
  - Restores exact prior preference values.
  - Deletes a preference only when it did not exist before the session.
  - Restarts Dock or Finder only when necessary.
  - Supports `--dry-run`.

### AppKit changes

The AppKit layer will:

- Add a Foreground Performance Session section to the scrollable Advanced window.
- Display an eligible-app list with checkboxes.
- Store selected bundle identifiers.
- Add manual buttons for refresh, dry-run, apply, restore, and state viewing.
- Keep script execution serialized through the existing centralized run-state lock.
- Run user-level apply steps before privileged Performance ON.
- Run privileged Performance OFF before user-level restore steps.
- Surface partial failures and restoration options clearly.

No system-changing logic will be duplicated in Swift.

## Preferences and State

All Foreground Performance Session files live under:

```text
~/Library/Application Support/CatalinaPerformance/foreground_session/
```

Expected structure:

```text
foreground_session/
├── preferences.env
├── runtime/
│   ├── session.env
│   ├── applications.tsv
│   └── ui_preferences.tsv
└── logs/
    ├── apply.log
    └── restore.log
```

### Preferences

`preferences.env` contains only recognized keys and selected bundle identifiers. Scripts must not use `eval` or execute file contents. Unknown or malformed keys are ignored with warnings.

The feature defaults to disabled. UI animation options are individually configurable.

### Runtime state

Runtime state records:

- Session identifier and timestamp.
- Bundle identifier.
- Application display name.
- Whether the application was running before apply.
- Whether CatalinaPerformance requested a quit.
- Whether the application was confirmed closed.
- Whether it should be relaunched.
- Relaunch result.
- UI preference domain, key, previous existence, previous type/value, and applied value.

The apply operation must abort before changes if the runtime directory or required state files cannot be created and read back.

## Graceful Application Closing

Application termination uses a normal macOS quit request by bundle identifier. The implementation must not use force-quit APIs or Unix signals.

For each selected application:

1. Confirm it is currently running.
2. Record pre-change state.
3. Request a normal quit.
4. Wait up to a documented bounded timeout.
5. Confirm whether it exited.
6. Mark it as `closed_by_catalina_performance=1` only after confirmed exit.

If an application displays a save dialog, refuses to quit, or remains running, it is recorded as skipped or still running. The session continues with other applications.

## Relaunch Rules

Restore relaunches an application only when all of these are true:

- It was running before the session.
- CatalinaPerformance requested it to quit.
- CatalinaPerformance confirmed it exited.
- It is not currently running.
- Its bundle identifier remains valid.

Applications that refused to close are not relaunched. Applications already running at restore time are skipped. Failed relaunch state is preserved for retry.

## UI Responsiveness Preferences

The first implementation may support these optional changes when reliable on Catalina:

- Disable Finder animations.
- Shorten Dock expose/launch animation durations.
- Disable general window animations.
- Reduce transparency only when the exact Catalina preference can be safely saved and restored.
- Reduce motion only when the exact Catalina preference can be safely saved and restored.

Each preference change follows this sequence:

1. Detect whether the preference exists.
2. Save its type and exact value if present.
3. Record absence if missing.
4. Apply the temporary performance value.
5. Restore the exact prior value later, or delete the key only if it was previously absent.

The scripts must not log the user out or reboot the Mac. Dock or Finder may be restarted only when the changed preference requires it.

## Performance Mode Integration

### ON sequence

1. Acquire the existing centralized GUI action lock.
2. Validate Foreground Performance Session configuration and state paths.
3. Run `foreground_session_apply.sh`.
4. Run `ui_responsiveness_apply.sh`.
5. Run the existing administrator-authorized `performance_on.sh`.
6. Refresh status and release the lock.

If the privileged Performance ON step fails after applications were closed or UI preferences were changed, the GUI must clearly offer immediate Foreground Session restoration. Automatic restoration is preferred when it can be performed safely without additional user decisions.

### OFF sequence

1. Acquire the existing centralized GUI action lock.
2. Run the existing administrator-authorized `performance_off.sh`.
3. Run `ui_responsiveness_restore.sh`.
4. Run `foreground_session_restore.sh`.
5. Refresh status and release the lock.

A user-level restore failure must not undo or hide a successful system-level Performance OFF restoration.

## Error Handling

- Every success, failure, cancellation, timeout, and early-exit path releases the centralized GUI action lock.
- State-write failures abort before changes.
- Partial application results are reported per application.
- Refused application quits are nonfatal.
- UI preference restore failures preserve state for retry.
- Relaunch failures preserve state for retry.
- Existing Performance ON/OFF and Emergency Restore behavior remains independently usable.
- Emergency Restore does not force-launch applications, but documentation must explain how to run the foreground-session restore manually.

## Security and Privacy

- No sudo is used by Foreground Session or UI-responsiveness scripts.
- Logs contain bundle identifiers, application names, timestamps, state transitions, and preference keys/values needed for restoration.
- Logs must not include document contents, window titles, browser URLs, or private application data.
- Preferences and runtime state are stored in the current user’s Application Support directory.

## GUI Design

Advanced → Foreground Performance Session includes:

- Explanatory text stating that the feature is opt-in and uses graceful quit only.
- Feature-enabled checkbox, default OFF.
- Refresh Running Applications button.
- Scrollable selectable application list.
- Display name, bundle identifier, and current running state.
- UI-responsiveness option checkboxes.
- Dry Run Performance Session button.
- Apply Performance Session Now button.
- Restore Performance Session button.
- View Foreground Session State button.
- Summary counts for selected, closed, skipped, and pending relaunch applications.

All script-launching controls respect the existing global action lock.

## Testing Strategy

### Static checks

- `git diff --check`
- `sh -n scripts/*.sh`
- `swift build` in `app/CatalinaPerformance`

### Script tests

Use harmless GUI applications such as TextEdit and Calculator:

1. Confirm listing includes eligible applications and excludes all permanent exclusions.
2. Confirm dry-run changes nothing.
3. Select TextEdit and Calculator and run apply.
4. Confirm normal quit requests are used.
5. Confirm applications that exit are marked closed.
6. Confirm an application that refuses to close is not force-quit.
7. Confirm restore relaunches only confirmed-closed applications.
8. Confirm already-running applications are not duplicated.
9. Confirm unwritable runtime state aborts before any quit request.
10. Confirm UI preferences restore to exact prior values and prior absence.

### GUI tests

1. Confirm the new Advanced section remains usable in the scrollable layout.
2. Confirm application selection persists by bundle identifier.
3. Confirm permanent exclusions never appear.
4. Confirm the centralized action lock blocks overlapping runs.
5. Confirm success, partial failure, cancellation, and timeout paths re-enable controls.
6. Confirm ON integrates user-level apply before privileged system changes.
7. Confirm OFF restores system settings before relaunching applications.
8. Confirm a failed privileged ON offers or performs user-level rollback.
9. Confirm existing status, Performance ON/OFF, Emergency Restore, Memory / Storage, App Priority report, and Thermal / Fan report remain functional.

## Documentation Updates

README and `docs/KNOWN_ISSUES.md` will explain:

- Foreground Performance Session is opt-in.
- Selected applications receive graceful quit requests only.
- Save dialogs or refusal can prevent closure.
- Only applications confirmed closed by CatalinaPerformance are relaunched.
- Restored applications may not recover identical windows or document state.
- Animation changes improve perceived responsiveness more than raw benchmark scores.
- The feature does not overclock, renice, control fans, or modify SIP.
- Terminal and iTerm are intentionally excluded in the first implementation.

## Success Criteria

The feature is complete when:

- Users can select eligible applications by bundle identifier.
- Apply safely closes selected applications without force quitting.
- Restore relaunches only confirmed-closed applications.
- UI preference changes restore exactly.
- State-write failure prevents all changes.
- ON/OFF integration remains reversible and recoverable.
- No existing CatalinaPerformance behavior regresses.
- The project builds with Xcode 12.4 on macOS Catalina.
