# WindowServer / GPU Pressure Monitoring Design

## Purpose

Extend CatalinaPerformance with read-only WindowServer pressure telemetry so Performance Mode can measure whether the existing Visual Performance optimizations correlate with reduced graphics/compositor load on macOS Catalina.

This patch is intentionally diagnostic. It must not introduce speculative graphics tweaks, adaptive preference changes, WindowServer restarts, display reconfiguration, wallpaper changes, GPU-driver changes, Quartz debug flags, or any other new graphics mutation path.

## Scope

The feature will:

- Reuse the existing Performance Session Dashboard sampling lifecycle.
- Collect three WindowServer samples over approximately four seconds before Performance Mode applies changes.
- Continue sampling WindowServer every two seconds while Performance Mode is active.
- Capture a final pre-restore reading and a post-restore reading.
- Classify WindowServer pressure as Normal, Elevated, High, or Unavailable using both absolute CPU use and deviation from the pre-ON baseline.
- Persist completed-session graphics telemetry and display it in a dedicated Graphics / WindowServer dashboard section.
- Provide informational advisories only.

The feature will not:

- Dynamically enable or disable visual settings in response to measured pressure.
- Change display resolution, scaling, refresh rate, calibration, wallpaper, or desktop rendering configuration.
- Restart or terminate WindowServer, Finder, Dock, or SystemUIServer.
- Modify graphics drivers, Quartz debug preferences, private compositor flags, or undocumented rendering controls.
- Add a new daemon, timer service, privileged helper, or administrator prompt.
- Duplicate the existing Visual Performance mutation subsystem.

## Relationship to Existing Visual Performance

Visual Performance remains the only subsystem responsible for changing visual preferences. Its existing typed capture, verified write, compare-before-restore, manual-change preservation, OFF restoration, Emergency Restore, and stale-session recovery behavior remain unchanged.

WindowServer pressure monitoring is read-only telemetry. The dashboard may report whether Visual Performance was active and whether restoration succeeded, but it must not claim that Visual Performance caused an observed CPU change.

Desktop icons and wallpaper are not part of this patch. The target machine already uses hidden desktop icons and a black static background, so no duplicate controls should be added.

## Architecture

### Reuse the Session Dashboard pipeline

The implementation will extend the existing Session Dashboard collector and coordinator rather than create a separate Graphics Pressure subsystem.

Reasons:

- The dashboard already captures a pre-ON baseline.
- It already samples on a utility queue every two seconds.
- It already persists active and completed sessions.
- It already captures pre-restore and post-restore state.
- A second timer or monitor would duplicate lifecycle, persistence, failure handling, and UI plumbing.

WindowServer telemetry therefore becomes another typed metric stream inside the existing dashboard architecture.

## Data Model

Introduce a typed WindowServer sample model containing at minimum:

- Timestamp
- PID
- Stable process identity fields required to detect PID replacement
- Cumulative CPU time
- Calculated CPU percentage when a valid prior sample exists
- Validity / availability state

A failed or unverifiable reading must never become 0%.

Completed-session graphics data should retain:

- The three raw pre-ON baseline samples
- Baseline average CPU
- Baseline peak CPU
- Active-session average CPU
- Active-session peak CPU
- Latest active reading
- Final pre-restore reading
- Post-restore reading
- Three-sample rolling average
- Maximum sustained pressure classification
- Time spent in Normal, Elevated, and High states
- Difference from baseline in percentage points where valid
- Whether Visual Performance was active
- Whether Visual Performance restoration succeeded

Unavailable values should remain explicitly unavailable through collection, persistence, aggregation, and presentation.

## WindowServer Discovery and CPU Calculation

The collector must identify the actual WindowServer process using a narrow, exact process identity rule. Fuzzy substring matching is not acceptable.

CPU usage should be calculated from cumulative CPU-time deltas over elapsed wall-clock time rather than trusting a single instantaneous `ps` percentage.

If WindowServer restarts or its PID changes:

1. Reject the stale identity.
2. Mark the affected delta sample unavailable.
3. Reacquire the real WindowServer process on a later sample.
4. Establish a new cumulative CPU-time baseline before calculating another percentage.

Negative deltas, zero/invalid elapsed time, ownership mismatch, executable mismatch, or any other unverifiable condition must produce Unavailable.

Monitoring failure must never block Performance Mode ON, OFF, Emergency Restore, or application shutdown.

## Baseline Measurement Lifecycle

When the user switches Performance Mode ON:

1. The UI enters a preparation state and shows `Measuring graphics baseline… 1/3`.
2. Capture WindowServer sample 1.
3. Approximately two seconds later capture sample 2 and show `2/3`.
4. Approximately two seconds later capture sample 3 and show `3/3`.
5. Compute the baseline average and peak from valid calculated CPU samples.
6. Continue with the existing Performance Mode activation sequence.

The preparation delay is intentional. A one-sample baseline is too weak for delta-based WindowServer CPU measurement.

After Performance Mode becomes active, WindowServer continues to use the existing two-second Session Dashboard sampling cadence.

When Performance Mode turns OFF or Emergency Restore begins:

1. Capture the existing final pre-restore session sample.
2. Restore normal system and Visual Performance state.
3. Capture the existing post-restore sample.
4. Persist the completed graphics comparison with the rest of the session report.

## Pressure Classification

Classification uses a three-sample rolling average where enough valid samples exist.

### Normal

Normal when both conditions are true:

- Rolling WindowServer CPU is below 15%.
- Rolling WindowServer CPU is less than 8 percentage points above the valid pre-ON baseline.

### Elevated

Elevated when either condition is true and the High conditions are not satisfied:

- Rolling WindowServer CPU is 15% through less than 30%.
- Rolling WindowServer CPU is at least 8 percentage points above baseline.

### High

A High candidate exists when either condition is true:

- Rolling WindowServer CPU is at least 30%.
- Rolling WindowServer CPU is at least 20% and at least 12 percentage points above baseline.

High is reported only after two consecutive High candidate classifications. This prevents a single Mission Control, window-open, or animation spike from producing a sustained-pressure warning.

### Unavailable

Unavailable when WindowServer cannot be identified or there are not enough trustworthy inputs to calculate the reading.

## Already-Elevated Baseline

The dashboard must distinguish pressure that existed before Performance Mode from pressure that developed during the session.

If the valid pre-ON baseline itself is elevated, the UI should state:

`Graphics pressure was elevated before Performance Mode started.`

The dashboard must not imply that Performance Mode caused a condition that was already present.

## Advisory Behavior

Classification is diagnostic only. No classification causes new system changes.

Recommended advisory text:

### Normal

`WindowServer load remained within the expected range.`

### Elevated

`WindowServer load was elevated during this session. No additional graphics changes were made automatically.`

### High

`Sustained WindowServer pressure was detected. Consider reducing the number of visible windows, displays, high-resolution content, or other graphics-heavy workloads.`

### Already elevated before ON

`Graphics pressure was elevated before Performance Mode started.`

Measured before/after differences may be displayed, but the app must not state that Visual Performance caused an improvement solely because active WindowServer CPU is lower than baseline.

## Session Dashboard UI

Add a dedicated `Graphics / WindowServer` section.

### Active session

Display:

- Pressure: Normal / Elevated / High / Unavailable
- Current CPU
- Three-sample rolling average
- Session average
- Session peak
- Pre-ON baseline
- Change from baseline
- Visual Performance status

Example:

```text
Graphics / WindowServer

Pressure:                 Elevated
Current CPU:              22.4%
Rolling average:          18.7%
Session average:          17.9%
Session peak:             34.2%
Pre-ON baseline:          11.1%
Change from baseline:     +6.8 points
Visual Performance:       Applied
```

### Completed session

Retain and present:

- Baseline average and peak
- Active-session average and peak
- Final pre-restore reading
- Post-restore reading
- Maximum sustained classification
- Time spent Normal / Elevated / High
- Visual Performance application status
- Visual Performance restoration status
- Advisory text

## Failure Handling

WindowServer telemetry is non-critical.

- Discovery failure: mark sample Unavailable and continue.
- Invalid CPU delta: mark sample Unavailable and continue.
- PID replacement: invalidate the stale delta, reacquire later, continue.
- Persistence of graphics metrics follows existing dashboard persistence rules.
- Monitoring failure never rolls back Performance Mode.
- Monitoring failure never blocks OFF or Emergency Restore.
- No authorization prompt is introduced.
- No monitoring error is interpreted as zero load.

## Performance and Threading

- Reuse the existing two-second dashboard sampler.
- Perform discovery and CPU-time reads off the AppKit main thread.
- Main thread work is limited to presentation updates.
- Do not add another repeating timer for WindowServer.
- Do not synchronously invoke expensive process inspection from AppKit event handlers.

## Testing

### Unit tests

Add coverage for:

- Exact Normal threshold boundaries.
- Exact Elevated threshold boundaries.
- Exact High threshold boundaries.
- Hybrid absolute-versus-relative classification.
- Three-sample rolling averages.
- Two-consecutive-High requirement.
- Already-elevated baseline handling.
- Missing baseline behavior.
- Missing WindowServer behavior.
- PID replacement and reacquisition.
- Negative CPU-time deltas.
- Invalid elapsed-time deltas.
- Unavailable readings remaining unavailable instead of becoming zero.
- Session average and peak aggregation.
- Time-in-state aggregation.
- Completed-report encoding and decoding.

### Coordinator tests

Verify:

- Exactly three graphics baseline samples occur before activation proceeds.
- Baseline progress reports 1/3, 2/3, and 3/3.
- The intended approximately four-second preparation sequence is scheduler-driven and testable without wall-clock sleeps.
- A WindowServer sampling failure still allows Performance Mode activation.
- Existing two-second active sampling remains intact.
- Final pre-restore and post-restore graphics samples are captured.
- Monitoring failures cannot block finalization.

### Dashboard tests

Verify active and completed rendering for:

- Normal
- Elevated
- High
- Unavailable
- Already-elevated baseline
- Visual Performance active
- Visual Performance restored
- Partial/unavailable metrics

### Regression tests

Verify no behavioral regression in:

- Visual Performance typed capture and restoration.
- Manual visual-setting change preservation.
- Temporarily Close Selected Apps.
- App Priority.
- Background Service Suppression.
- Session Dashboard persistence and restoration reporting.

### Catalina runtime verification

On the target Catalina Mac:

1. Confirm the real WindowServer can be discovered without administrator authorization.
2. Confirm cumulative CPU time can be sampled repeatedly.
3. Confirm the three-sample preparation sequence is visible before Performance Mode activates.
4. Confirm active WindowServer readings update every two seconds.
5. Exercise normal window activity, Mission Control, and a graphics-heavier workload to ensure transient spikes do not immediately become sustained High pressure.
6. Turn Performance Mode OFF and confirm the completed report contains baseline, active, pre-restore, and post-restore data.
7. Confirm WindowServer telemetry failure, if induced safely, does not block OFF or Emergency Restore.

## Acceptance Criteria

The patch is complete when:

- WindowServer monitoring is integrated into the existing Session Dashboard collector.
- Three pre-ON samples are collected over approximately four seconds before Performance Mode applies changes.
- Active sampling reuses the existing two-second scheduler.
- Pressure classification follows the approved hybrid rules and two-sample High confirmation.
- Completed reports persist the approved graphics metrics.
- The dashboard exposes a dedicated Graphics / WindowServer section and neutral advisories.
- No graphics preference changes are dynamically triggered by telemetry.
- No new daemon, privileged helper, or graphics mutation path exists.
- Monitoring failures remain non-blocking.
- Unit, coordinator, dashboard, regression, build, whitespace, and Catalina runtime checks pass.
