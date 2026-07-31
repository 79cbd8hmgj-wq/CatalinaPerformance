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

## App Priority Catalina Matrix

Use disposable TextEdit documents and noncritical browser tabs. Record each target's baseline with `ps -o pid,ppid,user,ni,comm -p <pid>` before changing Performance Mode.

1. Select TextEdit, enable App Priority, turn Performance Mode ON, and verify the TextEdit main process changes to nice `-5`; turn OFF and verify its exact original value returns.
2. Select Firefox and verify its main and eligible helper processes change to `-5`. Open a new tab or trigger a new helper and verify it is detected within four seconds.
3. Quit and relaunch Firefox while Performance Mode remains ON. Verify a newly tracked main-process identity and its helpers receive the boost.
4. Select Terminal and run an eligible same-user child command. Verify the child is included, while a root-owned child created through `sudo` is excluded.
5. Verify one administrator authorization prompt occurs for ON and the normal OFF authorization flow still occurs.
6. Cancel ON authorization after any user-level Foreground changes. Verify user-level rollback runs and no App Priority monitor remains.
7. Save an application selection while that app is absent. Turn ON, verify the status says Waiting, then launch the app and verify it is boosted.
8. Verify App Priority selection and enable controls are locked while Performance Mode is ON, while status continues updating.
9. Verify an application cannot be selected both for App Priority and for the Foreground close list, regardless of which feature is configured first.
10. While App Priority is active, run Emergency Restore. Verify monitoring stops and every still-matching record returns to its exact original nice value.
11. Reboot after saving an App Priority selection. Verify the selection remains remembered, no priority monitor starts automatically, and nice `-5` is not reapplied. If the broader Performance Mode marker remains recorded, use OFF or Emergency Restore to complete its normal recovery path.

The expected benefit is primarily under CPU contention. These tests do not validate higher CPU frequency, GPU, RAM, fan, or hardware performance because App Priority changes none of those.
