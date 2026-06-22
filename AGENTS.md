# AGENTS.md

Guidance for agents working in this repository.

## Project Intent

CatalinaPerformance targets macOS Catalina on older Intel Macs. The app should be built around a single Performance Mode ON/OFF switch with conservative, reversible system changes.

## Safety Requirements

All implementation work must follow these rules:

- Keep all changes reversible.
- Every system tweak must include a matching restore path in the same patch.
- Do not modify SIP.
- Do not delete caches automatically.
- Do not disable services permanently.
- Do not apply system changes without clear user intent.
- Prefer temporary runtime state over persistent configuration changes.

## Development Approach

- Build in small patches.
- Document behavior before implementing system-changing logic.
- Keep scripts safe to run on non-macOS systems when possible by detecting the platform before using macOS-only commands.
- For shell scripts, prefer POSIX-compatible `sh` unless a specific Bash feature is required.
- Avoid adding privileged operations until the restore behavior and user authorization flow are documented.

## Testing Expectations

For any future executable scripts or app code, include checks that verify:

- The ON path records prior state before changing anything.
- The OFF path restores prior state.
- Repeated ON/OFF cycles are safe.
- Failures leave the system in a known or recoverable state.
