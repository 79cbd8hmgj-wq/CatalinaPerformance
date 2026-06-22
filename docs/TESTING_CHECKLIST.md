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
