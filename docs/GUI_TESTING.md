# GUI Testing

Use this manual flow to verify the current CatalinaPerformance GUI on a macOS development machine. The AppKit GUI is intended for macOS Catalina-era Intel Macs and does not launch on non-macOS systems.

## Manual GUI Test Flow

1. Pull the latest repository changes:

   ```sh
   git pull
   ```

2. Build the Swift package from the app package directory:

   ```sh
   cd app/CatalinaPerformance
   swift build
   ```

3. Run the GUI and point it at the repository scripts directory:

   ```sh
   CATALINA_PERFORMANCE_SCRIPTS_DIR=/path/to/Catilinaperformance-/scripts swift run CatalinaPerformance
   ```

4. Click **Refresh Status**.

5. Verify output appears in the GUI output area. The output should include the command being run, script stdout/stderr, and an exit-status line.

6. Test **Performance ON**:

   - Click **Run Performance ON**.
   - Confirm any warning or confirmation text is clear before approving the action.
   - Verify the GUI reports success or a clear failure.
   - Confirm the status/output area updates after the script completes.

7. Test **Performance OFF**:

   - Click **Run Performance OFF**.
   - Verify the GUI reports success or a clear failure.
   - Confirm the status/output area updates after the script completes.
   - Confirm Performance Mode state returns to OFF when the restore path succeeds.

8. Run emergency restore if needed:

   ```sh
   /path/to/Catilinaperformance-/scripts/emergency_restore.sh
   ```

   Use this only when the normal OFF flow does not leave the system in the expected restored state.

## Safety Notes

- Do not test by manually editing app code or scripts during this flow.
- Keep the GUI pointed at the reviewed `scripts/` directory with `CATALINA_PERFORMANCE_SCRIPTS_DIR`.
- Do not introduce SIP changes, fan control, cache cleaning, launch daemon changes, undervolting, MSR changes, or kext changes while running GUI tests.


## Foreground Performance Session Matrix

Use harmless applications such as TextEdit and Calculator. Save all work before testing.

1. Open **Advanced → Foreground Performance Session** and verify the feature defaults to OFF.
2. Open TextEdit and Calculator, then click **Refresh Running Applications**. Verify both appear with durable bundle identifiers.
3. Verify CatalinaPerformance, Terminal, iTerm/iTerm2, Finder, Dock, SystemUIServer, WindowServer, and loginwindow never appear as selectable applications.
4. Select TextEdit and Calculator. Toggle each UI-responsiveness option and verify `~/Library/Application Support/CatalinaPerformance/foreground_session/preferences.env` contains only recognized keys and repeated `SELECTED_BUNDLE_ID=` lines.
5. Click **Dry Run Session**. Verify no application closes, no preference changes, and output describes only intended actions.
6. Enable the feature and click **Apply Session Now**. Verify selected applications receive normal quit requests. An application with an unsaved-document prompt must not be force-quit.
7. Click **View Session State**. Verify only applications confirmed closed are counted as pending relaunch.
8. Click **Restore Session**. Verify confirmed-closed applications relaunch, already-running applications are not duplicated, and refused applications are not launched.
9. Test exact preference restoration twice: once with each target preference already present, and once after deleting a target key. Verify the original scalar value is restored or the key is deleted only when it was previously absent.
10. Enable the feature and run Performance Mode ON. Verify the order in output is foreground apply, UI apply, then administrator-authorized Performance ON.
11. Cancel or fail the Performance ON authorization after foreground changes. Verify UI restore and application restore are automatically attempted and reported.
12. Run Performance Mode OFF. Verify system restoration is attempted first and UI/application restoration continues even if one step fails.
13. Make the runtime directory unwritable in a controlled test account. Verify apply aborts before any quit request.
14. Simulate a failed application relaunch. Verify runtime state remains pending and a later Restore Session retries it.
15. Confirm existing Refresh Status, Performance ON/OFF, Emergency Restore, App Priority report, Memory / Storage report, and Thermal / Fan report still work.

Do not use unsaved production documents for refusal/save-dialog tests. The feature cannot recreate identical windows or unsaved state after an application exits.

## Background Service Suppression Catalina Matrix

1. Confirm the Advanced panel lists macOS Updates, App Store Updates, Photos, Mail, Messages/FaceTime, Siri/Speech, and iCloud Drive separately. On the captured Catalina build, Siri/Speech and iCloud Drive should report **Unsupported** rather than being mutated.
2. Save baseline output for the supported preference keys and exact target processes before turning Performance Mode ON.
3. Turn Performance Mode ON and confirm only the finite catalog targets change: update preferences are paused and only matching user-owned worker identities receive SIGTERM.
4. Confirm the dashboard shows each supported category independently and does not convert missing evidence into Restored.
5. Open Photos, Mail, Messages, FaceTime, App Store, and Software Update one category at a time. Confirm the corresponding category becomes `Resumed — user opened ...` and remains exempt for the rest of that session.
6. Turn Performance Mode OFF and verify every update key returns to its exact prior presence/type/value and only workers recorded as running and successfully stopped are restarted.
7. Repeat ON/OFF to verify idempotency. Then repeat using Emergency Restore.
8. Force-quit CatalinaPerformance while ON, reopen it, and verify stale-session recovery restores user-owned workers without an automatic password prompt while root-setting recovery remains clearly outstanding until explicit restore authorization.
9. During active suppression, verify Safari password autofill, Keychain Access, AirDrop, Wi-Fi/DNS/browsing, a push notification, Finder, Dock, audio, and accessibility remain normal. Confirm diagnostic and crash-report processes are unchanged.
10. Compare alternating OFF/ON sessions without claiming causality. Record when targets were already idle or disabled.

## App Priority Catalina Matrix

Use disposable TextEdit documents and noncritical Firefox tabs. Record original nice values before each run. Stable Firefox testing must use the same Firefox profile, same starting tabs, same query, and the same completion criterion.

### Functional and restoration checks

1. Select TextEdit, enable App Priority, turn Performance Mode ON, and verify the verified same-user family uses nice `-5`; turn OFF and verify every still-matching process returns to its exact original value.
2. Select stable Firefox and confirm the saved executable is `/Applications/Firefox.app/Contents/MacOS/firefox`, not `plugin-container`, `Firefox GPU Helper`, or another helper.
3. Turn ON and compare the dashboard with:

```bash
ps -ww -axo pid=,ppid=,ni=,%cpu=,rss=,command= | grep -i '[F]irefox'
```

4. Confirm no more than three CatalinaPerformance-managed Firefox processes are at nice `-1`: the canonical parent/UI process, at most one verified GPU helper, and at most one positive-activity content-style process.
5. Confirm socket/network, RDD/data-decoder, utility, audio, crash-helper, idle preallocated, outside-bundle, and unverifiable processes retain their original priorities.
6. Confirm **Tracked Firefox Processes** may exceed **Processes Actually Boosted** and that dashboard parent/GPU/content PIDs match `ps` and `about:processes`.
7. Open another CPU-active page and observe for at least six seconds. A replacement content process must lead for two complete monitor cycles. The old target must return to its exact original nice value before the replacement becomes `-1`; a failed old restore must block the switch.
8. Quit and relaunch Firefox while ON. Confirm the new canonical parent and helpers are reacquired, CPU baselines reset, and stale PIDs are not reused.
9. Select Terminal and run an eligible same-user child command. Confirm the child can use the non-browser family policy while a root-owned `sudo` child is excluded.
10. Verify one administrator authorization prompt occurs for ON and the normal OFF authorization flow remains.
11. Cancel ON authorization after any user-level Foreground changes. Confirm rollback runs and no priority monitor remains.
12. Save an app that is not running, turn ON, and confirm **Waiting for selected app**; launch it and verify acquisition.
13. Confirm App Priority controls are locked while ON and Foreground close-list conflicts are refused in both configuration directions.
14. Run normal OFF, then repeat using Emergency Restore. Both paths must continue core Spotlight, Time Machine, power, UI, and temporary-app restoration even if one priority record cannot be restored.
15. Reboot after saving a selection. Confirm the selection remains, no monitor starts automatically, and no priority policy is reapplied.

### Alternating Firefox timing protocol

Run at least five App Priority OFF trials and five focused-ON trials in alternating order, such as `OFF, ON, ON, OFF, OFF, ON`, until both groups contain five results. For every trial:

- use the same Firefox profile and starting tabs;
- perform the same new-tab Google search;
- use the same start and completion points;
- record elapsed time and a brief subjective responsiveness note;
- record thermal scheduler/speed limits and whether the focused PIDs were correct.

One run is not evidence. A technically correct focused policy may be neutral or slower. Retain the experiment only if repeated Catalina results justify it. App Priority cannot improve network latency, and combined Firefox CPU can exceed 100% across cores.
