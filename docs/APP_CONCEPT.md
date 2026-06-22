# App Concept

CatalinaPerformance is a macOS Catalina utility for older Intel Macs that need a simple way to reduce background activity during focused work sessions.

## Main Interaction

The app centers on one primary control:

- **Performance Mode OFF**: default state. No active tweaks from CatalinaPerformance.
- **Performance Mode ON**: temporary state. The app applies only approved, reversible adjustments and shows live system status.

The switch should be easy to understand, easy to reverse, and explicit about what is currently active.

## Intended Performance Mode Behaviors

Future versions may include these reversible actions while Performance Mode is ON:

1. Prevent system sleep while the Mac is plugged in.
2. Pause Time Machine activity during the session.
3. Pause Spotlight indexing during the session.
4. Apply aggressive but safe thermal behavior where supported.
5. Surface status indicators that help the user decide whether Performance Mode is useful.

Each behavior must be independently restorable and visible in the UI.

## Status Indicators

The app should eventually show:

- CPU temperature
- Fan speed
- RAM pressure
- Swap usage
- Disk space
- Power source state
- Time Machine pause state
- Spotlight indexing pause state
- Sleep prevention state

## User Experience Goals

- One clear ON/OFF switch.
- Plain-language explanations for each active behavior.
- A visible restore path.
- No hidden permanent changes.
- Clear warnings when an action needs elevated privileges or is unsupported on a specific Mac.

## First Patch Scope

This initial repository patch only creates documentation and a placeholder status script. It does not implement a runnable app or system modifications.
