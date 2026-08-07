# Visual Performance

Visual Performance is an automatic, user-level subsystem of CatalinaPerformance's single Performance Mode switch. It is independent of **Temporarily Close Selected Apps**, App Priority, and Background Service Suppression.

## Automatic settings

Performance Mode applies only the following static Catalina 10.15.7 allowlist:

| Setting | Domain | Key | Applied value | Applicability |
|---|---|---|---|---|
| Finder animations | `com.apple.finder` | `DisableAllAnimations` | Boolean `true` | Always |
| Dock launch animation | `com.apple.dock` | `launchanim` | Boolean `false` | Always |
| Mission Control transitions | `com.apple.dock` | `expose-animation-duration` | Floating point `0.1` | Always |
| Window-opening animations | `NSGlobalDomain` | `NSAutomaticWindowAnimationsEnabled` | Boolean `false` | Always |
| Reduce Motion | `com.apple.universalaccess` | `reduceMotion` | Boolean `true` | Always |
| Reduce Transparency | `com.apple.universalaccess` | `reduceTransparency` | Boolean `true` | Always |
| Minimize effect | `com.apple.dock` | `mineffect` | String `scale` | Always |
| Dock auto-hide delay | `com.apple.dock` | `autohide-delay` | Floating point `0` | Only when Dock auto-hide is already enabled |
| Dock auto-hide animation | `com.apple.dock` | `autohide-time-modifier` | Floating point `0` | Only when Dock auto-hide is already enabled |

CatalinaPerformance never enables Dock auto-hide. The two conditional entries remain **Not applicable** when auto-hide is disabled.

## Apply guarantees

Before the first preference write, CatalinaPerformance:

1. Reads every applicable allowlisted key using `/usr/bin/defaults` directly, without shell interpolation.
2. Records whether the key existed, its supported scalar type, and its exact value.
3. Atomically writes the complete session record to:

   `~/Library/Application Support/CatalinaPerformance/visual_performance/active-session.json`

4. Reads the record back before beginning mutation.

Each setting is then written and verified by a fresh typed read. A failure is isolated to that setting. CatalinaPerformance immediately attempts to restore that setting's prior state and continues with the rest of Performance Mode unless durable recovery state cannot be maintained.

Finder and Dock settings may require those components to relaunch naturally before every visible effect appears. CatalinaPerformance does not terminate or signal Finder, Dock, SystemUIServer, WindowServer, or the user session.

## Compare-before-restore

Performance Mode OFF, Emergency Restore, startup recovery, and manual retry use the same rule for each setting:

- Restore the prior value only when the current value still equals CatalinaPerformance's applied value.
- Delete a key that was originally absent only when it still equals the applied value.
- Preserve a current value that differs from the applied value, because it may be a manual change made during the session.
- Keep failed restoration evidence for retry instead of reporting success.

When all settings are resolved, the completed record moves to:

`~/Library/Application Support/CatalinaPerformance/visual_performance/last-completed-session.json`

## Legacy UI state

Older builds stored animation state under the Foreground Performance Session runtime directory. New sessions do not create that state. At launch, CatalinaPerformance checks for unresolved legacy state and runs only the legacy restore path when necessary. The legacy apply script is unavailable to normal production sessions.

## Interface and dashboard

Advanced contains an informational Visual Performance section with:

- aggregate status;
- per-setting status and notes;
- a read-only **View Current Visual Settings** action;
- **Retry Visual Restoration** only when unresolved state exists.

The Session Dashboard reads Visual Performance state independently off the AppKit main thread and shows per-setting active or completed outcomes. Existing dashboard JSON remains backward-compatible because Visual Performance keeps its own versioned state files.

## Safety exclusions

Visual Performance does not:

- request administrator authorization;
- change display resolution, refresh rate, color, calibration, font smoothing, Quartz debugging, graphics drivers, GPU clocks, or application rendering settings;
- enable Dock auto-hide;
- log out the user or restart WindowServer;
- force-restart Finder or Dock;
- use arbitrary preference domains or keys;
- invoke `killall`, `launchctl`, `sudo`, or shell interpolation for preference operations.

## Catalina validation

Automated tests cover catalog identity, typed conversion, pre-state durability, fresh-read verification, isolated failure, manual-change preservation, originally-absent deletion, stale recovery, and unresolved restore retention.

Final release validation must still be performed on macOS Catalina 10.15.7 with Xcode 12.4:

1. Run the complete Swift and shell test suites.
2. Build both products and package the application.
3. Perform repeated ON/OFF cycles with Dock auto-hide disabled and enabled.
4. Change at least one managed preference manually while Performance Mode is ON and confirm OFF preserves it.
5. Terminate the app during an active session, relaunch it with Performance Mode OFF, and confirm startup recovery.
6. Confirm no preference drift after repeated cycles.
