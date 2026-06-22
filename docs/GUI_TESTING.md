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
