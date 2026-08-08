# Memory / Swap Read-Only Dashboard Revision

## Status

Approved design revision for CatalinaPerformance on macOS Catalina 10.15.7.

This specification supersedes the automatic-intervention portions of `2026-08-07-memory-pressure-swap-management-design.md`. The telemetry, classification, session aggregation, and dashboard work remain useful; automatic process mutation does not.

## Decision

Memory / Swap becomes a strictly read-only diagnostic subsystem.

CatalinaPerformance may observe, classify, aggregate, persist, and present memory and swap behavior. It must not change process scheduling, I/O policy, VM policy, application state, or system memory behavior in response to those observations.

## Why the design changed

Target-Mac runtime testing validated the detection pipeline but did not demonstrate a meaningful performance benefit from the intervention mechanism.

Observed behavior included:

- ordinary high memory use remaining Healthy when compression and swap were stable;
- genuine pressure reaching High only after sustained compression and swap activity;
- a large background Orion family being identified correctly;
- exact restoration of surviving Orion processes after intervention;
- `nice +5` and `nice +10` producing effectively indistinguishable scheduler-latency results in controlled A/B/C testing;
- no evidence strong enough to claim that CPU nice changes materially reduced swap pressure.

The user is primarily concerned with swap behavior. CPU scheduling priority does not directly reclaim memory or reduce the resident/compressed working set, so CatalinaPerformance should not present renicing as a memory or swap optimization.

## Goals

The read-only Memory / Swap subsystem should answer these questions clearly:

1. Is the Mac under meaningful memory pressure right now?
2. Is swap merely allocated, or is it actively growing/churning?
3. Is compressed memory stable or increasing rapidly?
4. Are page-outs occurring now?
5. How did memory pressure change during this Performance Session?
6. Was swap already elevated before Performance Mode began?
7. Which read-only evidence explains a Healthy, Elevated, High, or Critical classification?

## Non-goals and hard safety boundaries

The production Memory / Swap feature must not:

- change process nice values;
- invoke `renice` for memory-pressure management;
- start or package a Memory Management privileged agent;
- write desired-state or restoration-state files for memory management;
- use `taskpolicy` or any alternative I/O-priority mutation;
- terminate, suspend, kill, force-quit, or automatically close applications;
- disable swap;
- delete swap files;
- invoke automatic or periodic `purge`;
- modify compressor settings;
- modify documented or undocumented VM/kernel tunables;
- write arbitrary `vm.*` sysctls;
- unload daemons or services in response to memory pressure;
- mutate WindowServer, Finder, Dock, SystemUIServer, loginwindow, launchd, kernel_task, networking, AirDrop, Bluetooth, audio, Keychain/security, or any other system infrastructure;
- claim that CatalinaPerformance reduced swap unless future evidence and a separately approved design support that claim.

Unavailable telemetry must remain unavailable rather than being converted to zero.

## Architecture

The production data flow becomes:

```text
Catalina VM metrics
       |
       v
MemoryTelemetryCollector
       |
       |-- physical / available memory
       |-- compressed memory
       |-- compressor activity
       |-- swap used
       |-- swap-in / swap-out deltas
       |-- page-in / page-out deltas
       `-- rates / trends
       |
       v
MemoryPressureClassifier
       |
       |-- Healthy
       |-- Elevated
       |-- High
       `-- Critical
       |
       v
MemorySessionAggregate
       |
       v
Memory / Swap Dashboard Presentation
```

There is no production path from classification to mutation.

The following former path is removed:

```text
MemoryPressureClassifier
       X
       +--> BackgroundFamilyAnalyzer
       +--> MemoryManagementCoordinator
       +--> MemoryAgent
       +--> renice / taskpolicy
       +--> desired-state / restoration-state lifecycle
```

## Telemetry and sampling

### Cadence

Continue using the existing Performance Session sampling cadence. Memory / Swap must not add a separate high-frequency repeating timer.

### Read-only sources

Continue using Catalina-validated, read-only sources such as:

- `host_statistics64`;
- `host_page_size`;
- validated VM counters;
- read-only `vm.swapusage` evidence where required;
- other already-calibrated read-only Catalina sources.

### Required metrics

When supported, preserve:

- physical memory used;
- available memory;
- compressed memory;
- compression growth;
- swap used;
- swap growth;
- swap-in rate;
- swap-out rate;
- page-out activity;
- pressure state.

A pre-existing swap allocation is not equivalent to active pressure. Swap growth and swap-in/out activity remain distinct from total swap used.

## Pressure classification

Retain the existing multi-signal classifier and hysteresis because runtime testing showed that it distinguishes ordinary high memory usage from genuine VM contention.

States remain:

| State | Meaning | Action |
| --- | --- | --- |
| Healthy | No meaningful current VM contention | Observe and report |
| Elevated | Deterioration beginning | Observe and report |
| High | Sustained compression/paging pressure | Warn and report |
| Critical | Severe sustained VM contention | Warn prominently and report |

Classification never authorizes mutation.

The dashboard should explain pressure neutrally. Examples:

```text
Healthy — swap is allocated, but active swap growth is low.
```

```text
High — compressed memory and swap-out activity are increasing.
```

Warnings must describe observed evidence, not imply that CatalinaPerformance caused or fixed it.

## Live dashboard

The dedicated `Memory / Swap` section remains part of the Session Dashboard.

### Active-session rows

Keep:

- State
- Physical Used
- Available
- Compressed
- Compression Growth
- Swap Used
- Swap Growth
- Swap In
- Swap Out
- Page-Out Activity

Remove intervention-specific rows:

- Managed Workloads
- I/O Policy

The section may include a short read-only advisory when pressure is High or Critical, but no action button is part of this revision.

### Swap wording

The UI must distinguish allocation from activity.

Examples:

- `Swap Used: 580 MB` means swap is currently allocated.
- `Swap Growth: 0 MB/s` means total swap is not currently increasing.
- `Swap Out: 29 MB/s` means macOS is actively writing memory pages to swap.

The UI must not label nonzero swap alone as a failure.

## Completed-session dashboard

Retain read-only evidence that helps compare the beginning, peak, and end of a session:

- baseline pressure state;
- maximum pressure state;
- baseline compressed memory;
- peak compressed memory;
- peak compression growth;
- baseline swap used;
- peak swap used;
- endpoint swap used;
- net swap change;
- peak swap-in rate;
- peak swap-out rate;
- time in Healthy;
- time in Elevated;
- time in High;
- time in Critical.

Remove intervention-specific completed-session presentation:

- intervention episodes;
- managed family names;
- longest intervention duration;
- restoration result;
- I/O policy.

For backward compatibility, persisted session models may continue decoding legacy intervention fields from older sessions, but new sessions should not populate them and current presentation should not surface them.

`Net Swap` must retain causal-neutral wording. A lower or higher endpoint alone is not proof that Performance Mode improved or worsened performance.

## Advanced UI

Remove the `Memory Pressure Management` intervention panel and any wording such as:

- automatically active with Performance Mode;
- fixed nice +5;
- maximum managed workloads;
- I/O policy Supported/Unsupported/Active.

The existing read-only Memory / Storage area may remain and may link conceptually to the Session Dashboard, but it must expose no memory-pressure tuning controls.

If a read-only largest-memory-users view already exists or is inexpensive to retain, it may remain informational. It must not become an automatic candidate-management UI in this revision.

## Production packaging and lifecycle

The packaged application must not require or launch `CatalinaPerformanceMemoryAgent`.

Production ON/OFF/Emergency wrapper flows must no longer:

- validate a Memory Agent;
- start a Memory Agent;
- stop-and-restore a Memory Agent;
- export Memory Agent paths;
- depend on memory-management desired-state files.

`PerformanceSessionCoordinator` and `ProductionSessionMetricsCollector` should collect memory telemetry without constructing or owning a mutation coordinator.

Emergency Restore should continue restoring other approved mutable subsystems, but Memory / Swap has nothing to restore because it is read-only.

## Intervention-code retirement

Remove intervention-specific code from active production targets rather than leaving a callable but hidden mutation path.

This includes the production use of:

- background-family admission for memory mutation;
- `MemoryManagementCoordinator`;
- agent-confirmed mutation reconciliation;
- memory desired-state persistence;
- memory privileged-agent lifecycle;
- memory intervention controller;
- memory-specific renice mutation.

Shared read-only models or helpers may be retained when they are directly required by telemetry, classification, aggregation, or presentation.

Tests and package membership should be updated so a future refactor cannot accidentally reactivate mutation code without an explicit code change and test failure.

## Backward compatibility

Existing saved session JSON must continue to decode whenever practical.

Legacy fields from intervention-era sessions may remain optional in persistence models to avoid breaking historical session loading. New sessions should encode no active-intervention evidence.

No migration needs to rewrite historical files merely to remove old fields.

## Error handling

Telemetry errors remain fail-open and read-only:

- an unavailable signal is shown as unavailable;
- classification must not fabricate zero activity;
- a partial sample must not crash the session;
- the dashboard should continue presenting the trustworthy metrics that remain available.

Because no mutation occurs, telemetry failure creates no restoration obligation.

## Tests

### Unit tests

Retain or add coverage for:

- memory telemetry conversion and counter-reset behavior;
- multi-signal classification;
- sustained-state hysteresis;
- session aggregation;
- active and completed dashboard presentation;
- backward-compatible decoding of legacy session data.

### Source-safety tests

Add explicit source/package assertions that the production memory path contains no:

- Memory Agent startup;
- memory-pressure `renice` invocation;
- `taskpolicy` invocation;
- memory desired-state lifecycle;
- automatic application termination;
- swap disable/delete;
- `purge`;
- VM sysctl writes.

### Regression tests

Existing App Priority, Background Service Suppression, WindowServer monitoring, foreground-session handling, ON/OFF, and Emergency Restore tests remain required because the read-only revision must not regress unrelated subsystems.

### Catalina runtime acceptance

On the target Mac:

1. package and launch CatalinaPerformance;
2. confirm no `CatalinaPerformanceMemoryAgent` process is started;
3. confirm the package does not require the Memory Agent binary or memory-management wrapper dependency;
4. run a normal Performance Session and confirm Memory / Swap telemetry updates;
5. create bounded pressure and confirm states can progress through Elevated/High without changing process nice values;
6. confirm no memory-specific privileged runtime state is created under `/var/run/CatalinaPerformance/<uid>/memory_management`;
7. turn Performance Mode OFF and confirm Memory / Swap requires no restoration step;
8. verify other Performance Mode restoration paths remain correct.

## Acceptance criteria

The revision is accepted when all of the following are true:

- Memory / Swap remains a useful dedicated read-only Session Dashboard section;
- pressure classification still responds to real compression/swap activity;
- active and completed reports retain the approved read-only metrics;
- intervention-specific rows and wording are gone;
- no production memory-pressure code changes process priority or I/O policy;
- no Memory Agent is packaged, started, or required;
- no memory desired/restoration state is written during a session;
- historical session decoding remains compatible;
- unrelated Performance Mode features and restoration behavior continue to pass regression tests;
- Catalina runtime testing confirms observation without mutation.

## Future work

Any future attempt to reduce swap, reclaim application memory, terminate applications, suspend workloads, or otherwise act on High/Critical memory pressure requires a separate design, separate user approval, and independent evidence that the proposed intervention improves the target Mac without unacceptable side effects.
