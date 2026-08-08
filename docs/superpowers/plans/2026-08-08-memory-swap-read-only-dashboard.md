# Memory / Swap Read-Only Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every Memory / Swap system mutation while preserving Catalina-validated telemetry, pressure classification, session aggregation, and dashboard reporting.

**Architecture:** Keep `CatalinaPerformanceMemoryCore` only as a read-only telemetry/classification library. Delete the Memory Agent, mutation coordinator, desired/restoration state, process-family intervention path, and privileged wrapper lifecycle. The Session Dashboard continues sampling Memory / Swap on the existing session cadence and has no path from classification to mutation.

**Tech Stack:** Swift 5.2 / SwiftPM, AppKit on macOS Catalina 10.15.7, C host VM support, POSIX shell source-contract tests.

## Global Constraints

- Memory / Swap is strictly read-only.
- No `renice`, `taskpolicy`, process suspension/termination, `purge`, swap disable/delete, VM sysctl writes, or daemon unloading for memory management.
- No `CatalinaPerformanceMemoryAgent` product, package resource, launch, stop, or restore lifecycle.
- Keep existing Memory / Swap telemetry, classifier/hysteresis, aggregates, and dashboard rows that describe observed state.
- Remove intervention-specific UI/reporting: managed workloads, I/O policy, intervention episodes, managed family names, intervention duration, and memory restoration result.
- Existing unrelated Performance Mode ON/OFF/Emergency behavior must remain unchanged.
- Preserve practical decoding compatibility for older dashboard JSON.

---

### Task 1: Turn safety expectations into failing source tests

**Files:**
- Modify: `scripts/tests/test_memory_management_production_wiring_source.sh`
- Modify: `scripts/tests/test_memory_management_ui_source.sh`
- Modify: `scripts/tests/test_memory_management_wrappers.sh`
- Modify: `scripts/tests/test_session_dashboard_ui_source.sh`

**Interfaces:**
- Consumes: current package/wrapper/UI source tree.
- Produces: source contracts that require read-only memory behavior and reject Memory Agent/mutation wiring.

- [ ] **Step 1: Replace intervention assertions with read-only assertions**

Require the production tree to contain Memory / Swap telemetry/dashboard wiring but reject production references to `CatalinaPerformanceMemoryAgent`, `MemoryManagementCoordinator`, `MemoryInterventionController`, memory desired-state lifecycle, memory-specific `renice`, and `taskpolicy`.

- [ ] **Step 2: Run the focused source tests and verify they fail against the current intervention implementation**

Run:

```bash
/bin/sh scripts/tests/test_memory_management_production_wiring_source.sh
/bin/sh scripts/tests/test_memory_management_ui_source.sh
/bin/sh scripts/tests/test_memory_management_wrappers.sh
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
```

Expected: at least one FAIL because the Memory Agent/mutation path is still present.

- [ ] **Step 3: Commit the test-first contract**

```bash
git add scripts/tests/test_memory_management_production_wiring_source.sh \
        scripts/tests/test_memory_management_ui_source.sh \
        scripts/tests/test_memory_management_wrappers.sh \
        scripts/tests/test_session_dashboard_ui_source.sh
git commit -m "test: require read-only memory swap behavior"
```

---

### Task 2: Remove Memory Agent and mutation core from production

**Files:**
- Modify: `app/CatalinaPerformance/Package.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryAgent/main.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/AgentConfirmedMemoryManagementCoordinator.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryAgentConfirmedState.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryAgentService.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryAgentStateStore.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryDesiredStateStore.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryInterventionController.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementCoordinator.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryManagementStateModels.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore/MemoryProcessFamilyAnalyzer.swift`
- Delete corresponding intervention-only tests under `app/CatalinaPerformance/Tests/CatalinaPerformanceMemoryTests/`.

**Interfaces:**
- Retains: `CatalinaMemoryCapabilities`, `MemoryPressureClassifier`, `MemoryTelemetryCollector`, `MemoryTelemetryModels` and tests.
- Produces: a MemoryCore target with no process-mutation capability.

- [ ] **Step 1: Remove the `CatalinaPerformanceMemoryAgent` product and target**

Also remove PriorityCore as a MemoryCore dependency if no retained read-only source needs it.

- [ ] **Step 2: Delete mutation-only source and tests**

Keep only files needed for telemetry, capabilities, classification, aggregation, and presentation.

- [ ] **Step 3: Run MemoryCore tests**

```bash
cd app/CatalinaPerformance
swift test --filter CatalinaPerformanceMemoryTests
cd ../..
```

Expected: retained read-only memory tests pass and no Memory Agent target is built.

- [ ] **Step 4: Commit**

```bash
git add -A app/CatalinaPerformance
git commit -m "refactor: remove memory intervention engine"
```

---

### Task 3: Remove production lifecycle/UI/wrapper mutation wiring

**Files:**
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformance/MemoryManagementPanelController.swift`
- Delete: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/MemoryFrontmostApplicationObserver.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/ProductionSessionMetricsCollector.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/MemorySessionAggregate.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/MemorySessionDashboardPresentation.swift`
- Modify: `app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift`
- Modify: `scripts/package_app.sh`
- Modify: `scripts/performance_on_with_priority.sh`
- Modify: `scripts/performance_off_with_priority.sh`
- Modify: `scripts/emergency_restore_with_priority.sh`
- Delete: `scripts/lib/memory_management_wrapper_common.sh`

**Interfaces:**
- `ProductionSessionMetricsCollector` constructs `DarwinMemoryTelemetryCollector()` only.
- Session coordinator consumes memory telemetry snapshots but owns no memory mutation coordinator.
- Dashboard keeps: State, Physical Used, Available, Compressed, Compression Growth, Swap Used, Swap Growth, Swap In, Swap Out, Page-Out Activity.

- [ ] **Step 1: Remove Advanced intervention UI and main-app observer wiring**

Keep the existing read-only Memory / Storage information and Session Dashboard Memory / Swap section.

- [ ] **Step 2: Remove coordinator/intervention lifecycle from dashboard collection**

The collector should sample memory telemetry on the existing cadence and never emit a desired mutation state.

- [ ] **Step 3: Remove intervention-specific dashboard fields from new presentation**

Legacy optional persistence fields may remain decodable, but do not populate or display them for new sessions.

- [ ] **Step 4: Remove Memory Agent packaging and wrapper calls**

ON/OFF/Emergency wrappers must no longer validate, start, stop, restore, or export any memory agent/state path.

- [ ] **Step 5: Run focused contracts**

```bash
/bin/sh scripts/tests/test_memory_management_production_wiring_source.sh
/bin/sh scripts/tests/test_memory_management_ui_source.sh
/bin/sh scripts/tests/test_memory_management_wrappers.sh
/bin/sh scripts/tests/test_session_dashboard_ui_source.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: make memory swap diagnostics read only"
```

---

### Task 4: Full regression and package safety gate

**Files:**
- Modify only if required by regression fallout: existing test/package documentation files.

**Interfaces:**
- Produces: package with no Memory Agent and no Memory / Swap mutation path.

- [ ] **Step 1: Run regression shell tests**

```bash
/bin/sh scripts/tests/test_foreground_session.sh all
/bin/sh scripts/tests/test_advanced_layout_source.sh
/bin/sh scripts/tests/test_app_priority_wrappers.sh
/bin/sh scripts/tests/test_app_priority_ui_source.sh
/bin/sh scripts/tests/test_catalina_process_support_source.sh
/bin/sh scripts/tests/test_background_service_probe.sh
/bin/sh scripts/tests/test_background_service_settings.sh
/bin/sh scripts/tests/test_background_service_wrappers.sh
/bin/sh scripts/tests/test_background_service_ui_source.sh
/bin/sh scripts/tests/test_windowserver_pressure_source.sh
```

Expected: PASS.

- [ ] **Step 2: Run Swift regression and builds**

```bash
cd app/CatalinaPerformance
rm -rf .build
swift test
swift build --product CatalinaPerformance
swift build --product CatalinaPerformancePriorityAgent
cd ../..
git diff --check
```

Expected: all tests pass, both remaining products build, and `git diff --check` is clean.

- [ ] **Step 3: Package and confirm Memory Agent absence on Catalina**

```bash
rm -rf build
/bin/sh scripts/package_app.sh
test ! -e build/CatalinaPerformance.app/Contents/Resources/bin/CatalinaPerformanceMemoryAgent
```

Expected: package succeeds and the Memory Agent binary is absent.

- [ ] **Step 4: Runtime acceptance on target Mac**

Run one ordinary Performance Session. Confirm Memory / Swap updates in the dashboard, no Memory Agent process exists, no memory-management runtime/desired-state is created, and process nice values are untouched by Memory / Swap.
