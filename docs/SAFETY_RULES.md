# Safety Rules

CatalinaPerformance must be safe, reversible, and transparent. The app targets macOS Catalina on older Intel Macs, where users may rely on system stability and may not have modern recovery options.

## Hard Rules

These rules are mandatory for all future patches:

1. **Keep all changes reversible.**
2. **Every system tweak must have a matching restore path.**
3. **Do not modify SIP.**
4. **Do not delete caches automatically.**
5. **Do not disable services permanently.**
6. **Do not hide system changes from the user.**
7. **Do not require a reboot as the normal restore mechanism.**

## Restore-First Design

Before applying any system tweak, the app must know how it will restore the previous state. A future implementation should generally follow this order:

1. Detect platform and capability.
2. Read and store current state.
3. Validate that a restore command or API path exists.
4. Apply the temporary change.
5. Confirm the change took effect.
6. Restore on OFF, app quit, error, or session timeout where possible.

## Prohibited Behaviors

The app must not:

- Modify SIP settings.
- Permanently unload or disable launch daemons or launch agents.
- Automatically delete user, system, application, or kernel caches.
- Disable Time Machine permanently.
- Disable Spotlight permanently.
- Assume that all Intel Macs expose the same sensors or fan controls.
- Apply thermal or power changes without documenting the restore path.

## Privilege Model

Future privileged operations must be minimized and explicit. Prefer user-level APIs and temporary assertions before using elevated privileges. If a privileged helper is added later, it must expose a narrow command surface and include tests for both apply and restore paths.

## Failure Handling

If applying a tweak fails partway through, CatalinaPerformance should:

- Stop applying additional changes.
- Attempt to restore any changes already made.
- Report what succeeded, what failed, and what still needs user attention.
- Never pretend Performance Mode is fully active when only part of it succeeded.
