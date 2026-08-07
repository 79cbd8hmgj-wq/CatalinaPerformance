# WindowServer / GPU Pressure Runtime Checklist

This checklist validates the read-only WindowServer / GPU Pressure Monitoring feature on the target Intel Mac running macOS Catalina 10.15.7. It does not authorize any new graphics mutation behavior.

## Catalina Runtime Procedure

1. Launch the packaged `CatalinaPerformance.app` normally.
2. Open **Session Dashboard** before starting a session and confirm the window opens without a crash or Auto Layout exception.
3. Turn **Performance Mode ON**.
4. Confirm the dashboard status progresses through `Measuring graphics baseline… 1/3`, then `2/3`, then `3/3` over roughly four seconds before the existing Performance Mode activation sequence continues.
5. Confirm Performance Mode proceeds even if the **Graphics / WindowServer** section reports **Unavailable**.
6. While ON, keep Session Dashboard open and confirm **Current CPU** updates on the existing two-second dashboard cadence.
7. Exercise ordinary window opening, Mission Control, and normal desktop interaction. Verify one transient CPU spike does not immediately become sustained **High** pressure.
8. Run a graphics-heavier workload long enough to observe **Elevated** or **High** only if the Mac naturally reaches those thresholds. Do not force instability or alter display settings merely to trigger a classification.
9. Turn **Performance Mode OFF**.
10. Confirm the completed report contains baseline average/peak, active average/peak, final pre-restore, post-restore, maximum sustained pressure, and time spent Normal/Elevated/High when those readings are available.
11. Confirm the separate **Visual Performance** restoration section still reports its own applied/restored evidence independently. Do not interpret a lower post-restore or active WindowServer reading as proof that Visual Performance caused the difference.
12. Confirm normal OFF and **Emergency Restore** remain usable when WindowServer telemetry is unavailable.

## Required Safety Assertions

- WindowServer monitoring causes no administrator authorization prompt.
- WindowServer discovery is exact and does not select similarly named helpers.
- A WindowServer PID/start-identity change produces an Unavailable interval and a fresh counter baseline rather than reusing a stale delta.
- Missing, invalid, or ambiguous telemetry displays **Unavailable**, never `0%`.
- WindowServer CPU may legitimately exceed `100%` across CPU cores and must not be clamped to `100%`.
- No WindowServer, Finder, Dock, or SystemUIServer restart, signal, priority mutation, or termination occurs.
- No `killall`, `pkill`, `renice`, `defaults write ... WindowServer`, LaunchDaemon, helper daemon, kext, SIP, SMC, MSR, or undervolting path is introduced by this feature.
- No resolution, scaling, refresh-rate, color-profile, wallpaper, desktop-icon, Quartz-debug, or private graphics-driver setting changes occur.
- The active WindowServer sample is collected by the existing Session Dashboard two-second scheduler; there is no second repeating telemetry timer.
- Telemetry failure never rolls back Performance Mode and never blocks OFF or Emergency Restore.

## Classification Verification

For observed readings, verify the dashboard follows the approved diagnostic rules:

- **Normal:** rolling CPU is below `15%` and, when a valid baseline exists, less than `+8` percentage points above baseline.
- **Elevated:** when not High, rolling CPU is at least `15%` but below `30%`, or at least `+8` percentage points above a valid baseline.
- **High candidate:** rolling CPU is at least `30%`, or is at least `20%` and at least `+12` percentage points above a valid baseline.
- **High:** only after two consecutive High candidates.
- **Unavailable:** WindowServer cannot be uniquely identified or a trustworthy CPU delta cannot be calculated.

If the valid pre-ON baseline is already elevated, the UI must say: `Graphics pressure was elevated before Performance Mode started.`

## Advisory Copy

The dashboard must remain causal-neutral:

- Normal: `WindowServer load remained within the expected range.`
- Elevated: `WindowServer load was elevated during this session. No additional graphics changes were made automatically.`
- High: `Sustained WindowServer pressure was detected. Consider reducing the number of visible windows, displays, high-resolution content, or other graphics-heavy workloads.`

Do not accept wording that claims Visual Performance reduced WindowServer load solely from before/after measurements.
