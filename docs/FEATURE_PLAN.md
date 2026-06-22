# Feature Plan

CatalinaPerformance will be built in small patches. This plan is intentionally staged so safety and reversibility come before system-changing behavior.

## Phase 0: Repository Foundation

- Add README and agent guidance.
- Document the app concept.
- Document safety rules.
- Add a testing checklist.
- Add a placeholder status script.

## Phase 1: Passive Status Reporting

Implement read-only status collection before changing system behavior:

- macOS version and hardware architecture.
- Power source state.
- Disk free space.
- Memory pressure and swap usage where available.
- Sensor and fan availability investigation for Intel Catalina systems.

## Phase 2: Sleep Prevention Session

Add the first reversible Performance Mode behavior:

- Use a temporary sleep-prevention mechanism only while Performance Mode is ON.
- Apply only when appropriate for AC power.
- Restore by releasing the active assertion/process.
- Test repeated ON/OFF cycles.

## Phase 3: Time Machine Pause Session

Add temporary Time Machine behavior only after restore semantics are validated:

- Detect current Time Machine state.
- Pause or defer activity for the current session.
- Restore the previous state on OFF.
- Clearly report unsupported or permission-denied states.

## Phase 4: Spotlight Indexing Pause Session

Add temporary Spotlight behavior only with explicit restore tracking:

- Record current indexing state per affected volume.
- Pause indexing only for the intended session.
- Restore the previous state for each volume on OFF.
- Avoid permanent indexing disablement.

## Phase 5: Thermal and Fan Investigation

Investigate safe Intel Mac thermal options:

- Prefer read-only telemetry first.
- Avoid unsupported private behavior unless clearly documented and reversible.
- Do not force unsafe fan or thermal states.
- Provide user-visible unsupported states rather than guessing.

## Phase 6: App Shell

Create the actual macOS app after the safety model and core behaviors are proven:

- Main Performance Mode switch.
- Status dashboard.
- Clear apply/restore logs.
- Error and unsupported-state handling.
