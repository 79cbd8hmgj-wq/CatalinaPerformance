# CatalinaPerformance

CatalinaPerformance is an early-stage macOS utility concept for older Intel Macs running macOS Catalina. The long-term goal is a simple, reversible **Performance Mode** toggle that temporarily reduces background activity and surfaces basic system health signals while the Mac is plugged in.

This repository is intentionally starting small. The first patches document the product goals, safety rules, planned features, and testing checklist before any system-changing code is added.

## Target Platform

- macOS Catalina 10.15
- Older Intel-based Macs
- User-controlled, reversible performance adjustments

## Core Concept

The app will eventually provide one main switch:

- **Performance Mode ON**: apply temporary, reversible settings intended to reduce background work and keep the Mac awake while on AC power.
- **Performance Mode OFF**: restore every setting changed by the app to its previous state.

Planned status indicators include:

- CPU temperature
- Fan speed
- RAM pressure
- Swap usage
- Disk space
- Whether sleep, Time Machine, Spotlight indexing, and thermal behavior adjustments are active

## Non-Goals for Early Patches

This repository now includes a minimal local macOS GUI shell. It does **not** implement a privileged helper, fan control, advanced options, launch daemon toggles, cache cleaning, undervolting, MSR changes, kext changes, SIP changes, or irreversible system tweaks. Future behavior should be built in small, reviewable patches after the safety model is documented.

## Safety Principles

CatalinaPerformance must be conservative by default:

- Keep all changes reversible.
- Every system tweak must have a matching restore path.
- Do not modify System Integrity Protection (SIP).
- Do not delete caches automatically.
- Do not disable services permanently.
- Prefer temporary sessions and explicit user consent over persistent changes.

See [docs/SAFETY_RULES.md](docs/SAFETY_RULES.md) for the detailed safety contract.

## Repository Layout

```text
.
├── README.md
├── AGENTS.md
├── docs/
│   ├── APP_CONCEPT.md
│   ├── FEATURE_PLAN.md
│   ├── SAFETY_RULES.md
│   └── TESTING_CHECKLIST.md
├── app/
│   └── CatalinaPerformance/
│       ├── Package.swift
│       └── Sources/CatalinaPerformance/main.swift
└── scripts/
    ├── emergency_restore.sh
    ├── performance_off.sh
    ├── performance_on.sh
    ├── status_report.sh
    └── test_performance_cycle.sh
```

## Current Status

Initial documentation, safe script scaffolding, and a minimal local GUI shell are present. Production packaging and privileged helper behavior are not implemented yet.

## Local GUI Development

A minimal macOS GUI shell now lives in `app/CatalinaPerformance`. It is a Swift Package Manager AppKit executable targeting macOS Catalina 10.15 and older Intel Macs.

The GUI is intentionally thin:

- It displays the CatalinaPerformance app name, a Performance Mode ON/OFF switch, a status area, script output, and buttons for status refresh, Performance ON, Performance OFF, Emergency Restore, and an Advanced placeholder.
- The Advanced area is only a placeholder and says: `Advanced options are not implemented yet.`
- It calls the existing scripts in `scripts/` instead of duplicating system-changing logic.
- It does not implement fan control, cache cleaning, SIP changes, launch daemon toggles, undervolting, MSR changes, kext loading, or experimental features.
- It shows warning confirmations before running Performance ON or Emergency Restore.

From a macOS Catalina development machine with Xcode command line tools installed:

```sh
cd app/CatalinaPerformance
swift run CatalinaPerformance
```

By default, the development build resolves scripts relative to the repository checkout. If you run the app from another working directory, set the scripts directory explicitly:

```sh
CATALINA_PERFORMANCE_SCRIPTS_DIR=/path/to/Catilinaperformance-/scripts swift run CatalinaPerformance
```

Future packaged `.app` work should keep the same app/script boundary: the GUI may collect user intent and display output, while reversible system behavior and restore paths remain in reviewed scripts.
