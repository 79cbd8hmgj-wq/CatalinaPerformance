# Memory Pressure & Swap Management 1.0 Design

## Status

Approved design for CatalinaPerformance on macOS Catalina 10.15.7.

## Goal

Add a Catalina-specific memory-pressure management subsystem that detects sustained virtual-memory contention, identifies verified noncritical background application families that are materially contributing to memory pressure, temporarily deprioritizes at most three qualifying families, and restores their exact original scheduling state automatically when memory conditions recover or immediately when user activity or Performance Mode state requires it.

The subsystem is intended to improve responsiveness under genuine compression, paging, and swap pressure. It must not treat high RAM usage by itself as a problem and must not attempt to replace macOS virtual-memory management.

## Non-goals and hard safety boundaries

Memory Pressure & Swap Management 1.0 must not:

- disable swap;
- delete swap files;
- invoke periodic or automatic `purge` behavior;
- modify compressor or undocumented VM/kernel tunables;
- write arbitrary `vm.*` sysctls;
- terminate, kill, force-quit, or unload arbitrary applications or daemons;
- automatically close user applications;
- raise a process above its original scheduling priority;
- deprioritize the foreground application;
- deprioritize the configured App Priority target;
- mutate WindowServer, Finder, Dock, SystemUIServer, loginwindow, launchd, kernel_task, CatalinaPerformance, root-owned processes, or protected system infrastructure;
- interpret unavailable telemetry as zero;
- mutate a process that cannot be reverified by PID, UID, executable path, and process start time;
- add an unverified I/O policy mechanism.

At Critical memory pressure, the subsystem remains within the same approved intervention policy. It may warn that pressure remains severe, but it does not escalate to more aggressive nice values, application termination, VM manipulation, or daemon unloading.

## Existing architecture to reuse

The implementation should build on existing CatalinaPerformance patterns rather than introduce a parallel unsafe control path:

- the existing 2-second Performance Session sampling cadence;
- existing process identity verification used by App Priority;
- existing reversible state persistence and stale-session recovery patterns;
- existing Background Service Suppression coordination;
- existing Session Dashboard persistence and completed-session reporting;
- existing Emergency Restore philosophy.

Memory Management should be an isolated subsystem with clear interfaces for telemetry, classification, family analysis, mutation, persistence, and presentation.

## High-level architecture

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
BackgroundFamilyAnalyzer
       |
       |-- same-user processes only
       |-- resident-memory attribution
       |-- verified ancestry / application identity
       |-- foreground exclusion
       |-- App Priority exclusion
       |-- protected-system exclusion
       `-- sustained-background requirement
       |
       v
MemoryInterventionController
       |
       |-- maximum 3 process families
       |-- nice +5
       |-- calibrated taskpolicy treatment only if proven safe
       |-- exact original state persisted first
       `-- automatic hysteresis recovery
```

## Sampling and telemetry

### Sampling cadence

Memory Management reuses the existing 2-second Performance Session sampling cadence. It must not add another high-frequency repeating timer for VM telemetry.

### Required telemetry candidates

The Catalina capability probe must determine which of the following are trustworthy on the actual Catalina 10.15.7 machine:

- physical RAM;
- available RAM;
- active pages;
- inactive pages;
- wired pages;
- speculative pages;
- purgeable pages;
- compressed-memory pages / bytes;
- pages stored in the compressor;
- cumulative compressions;
- cumulative decompressions;
- page-ins;
- page-outs;
- swap-ins;
- swap-outs;
- total, used, and free swap;
- a native macOS memory-pressure state, if Catalina exposes one reliably.

Potential read-only evidence sources include:

```text
vm_stat
memory_pressure
sysctl vm.swapusage
relevant read-only vm.* sysctls
host_statistics64
host_page_size
```

No metric enters the production classifier merely because it exists on a newer macOS release or is documented elsewhere.

### Counter requirements

A cumulative counter must demonstrate:

1. known units;
2. sane values on Catalina;
3. expected monotonic behavior;
4. repeatability across successive samples;
5. a defined reset, rollback, or overflow path.

Counter decreases or resets produce an unavailable delta for that interval. They must never be converted to zero activity.

### Rates

Cumulative counters are converted into deltas and rates using the actual elapsed interval. The UI may express useful rates in MB/min while the classifier may retain byte/second values internally.

### Baseline

Performance Mode establishes a short memory baseline before automatic intervention is allowed. Baseline evidence includes at least:

- available memory;
- compressed memory, when supported;
- swap used;
- available cumulative VM counters.

A large pre-existing swap allocation must not be confused with new swap growth.

If memory pressure is already elevated before Performance Mode begins, the dashboard must say so explicitly instead of implying that Performance Mode caused it.

## Pressure classification

### States

| State | Meaning | Automatic action |
| --- | --- | --- |
| Healthy | No meaningful VM contention | None |
| Elevated | Deterioration beginning | Observe only |
| High | Sustained compression/paging pressure | Intervention permitted |
| Critical | Severe sustained VM contention | Maintain approved intervention and warn |

The current simple available-memory classifier may remain for backward-compatible dashboard data, but it must not independently authorize mutation.

### Multi-signal requirement

Automatic intervention is based on sustained multi-signal deterioration. Ordinary high RAM utilization does not trigger it.

Candidate evidence includes:

#### Available-memory pressure

- below 15% physical RAM available: moderate evidence;
- below 8%: strong evidence;
- below 5%: severe evidence.

#### Compressed memory

- compressed memory at or above 20% of physical RAM: moderate evidence;
- at or above 30%: strong evidence;
- sustained positive compression growth: additional evidence.

#### Swap

- swap merely being nonzero is not evidence of current pressure;
- increasing swap usage contributes evidence;
- sustained swap-out activity contributes strong evidence;
- simultaneous swap-in and swap-out churn contributes strong evidence.

#### VM activity

- sustained compressor and page-out activity contributes evidence;
- one short burst does not.

#### Native pressure state

If a Catalina-native pressure state is verified, Warning and Critical states become strong inputs, but they do not bypass the multi-sample requirement.

### Calibration-derived rate thresholds

Exact byte/rate thresholds for compression growth, swap growth, page-outs, and swap churn are intentionally capability-calibrated rather than guessed in advance.

This is not an open-ended production setting. The implementation must follow this sequence:

1. collect Catalina capability evidence;
2. confirm units and counter behavior;
3. select conservative static Catalina constants;
4. record those constants in the implementation's Catalina capability/profile code and tests;
5. keep automatic mutation disabled until those constants are reviewed and committed.

If a metric cannot be calibrated, it remains Unsupported and contributes no classifier evidence.

### Sustained-state rules

At the 2-second sampling cadence:

```text
1 abnormal sample
-> never intervene

3 consecutive Elevated candidates
-> state becomes Elevated

3 consecutive High candidates
-> state becomes High
-> intervention permitted

2 consecutive Critical candidates
-> state becomes Critical
-> intervention permitted
```

A transient launch, tab creation, or short compressor burst must not immediately alter process scheduling.

### Recovery hysteresis

After intervention, restoration requires five consecutive Healthy samples, approximately 10 seconds at the normal sampling cadence.

```text
High / Critical
      |
      v
pressure improves
      |
      v
5 consecutive Healthy samples
      |
      v
restore exact original policies
```

Any Elevated, High, or Critical sample resets the Healthy recovery counter.

Performance Mode OFF, foreground activity, App Priority conflict, or Emergency Restore overrides this timer and may require immediate restoration.

### Example: high usage without active pressure

```text
RAM Used:       7.2 GB
Swap Used:      1.1 GB
Swap Growth:    0 MB/min
Compression:    stable
Pressure:       Healthy
```

No intervention occurs.

### Example: active contention

```text
RAM Available:       falling
Compressed Memory:   +240 MB/min
Swap Growth:         +160 MB/min
Swap Outs:           sustained
Pressure:            High
```

Intervention is permitted after the sustained-state confirmation rules pass.

## Process-family eligibility

A workload may enter the candidate pool only when every eligibility requirement passes.

### Required conditions

The family must:

- belong to the logged-in user;
- have stable process identity information;
- remain in the background for at least 3 consecutive samples;
- not contain the current frontmost application;
- not be the configured App Priority target;
- not be CatalinaPerformance or one of its helper processes;
- contribute meaningful resident memory;
- include at least one process whose memory can be measured reliably.

Three consecutive background samples correspond to approximately 6 seconds before a family becomes eligible.

If frontmost-application identity is unavailable, the subsystem must fail safe by refusing to admit new families until that state can be determined reliably.

### Protected infrastructure

The following are permanently excluded regardless of memory footprint:

```text
launchd
kernel_task
WindowServer
loginwindow
SystemUIServer
Finder
Dock
CatalinaPerformance
```

The production protection policy must also cover verified Catalina infrastructure associated with:

- Wi-Fi, networking, and DNS;
- AirDrop;
- Bluetooth;
- audio;
- Keychain, passwords, and security services;
- login and session management;
- disk and filesystem infrastructure required for normal operation;
- mechanisms CatalinaPerformance depends on for restoration.

No fuzzy process-name match may authorize mutation. Protection should use exact executable paths, bundle/application identity, verified ownership, and static Catalina allow/deny policy where practical.

## Process-family construction

Processes are not grouped merely because their executable names match.

Families are constructed from verified process relationships and application identity. Multi-process workloads such as browsers and Electron applications should be treated as a coherent workload for ranking while preserving per-process mutation and restoration records.

Example:

```text
Firefox.app
|-- firefox
|-- content processes
|-- GPU helper
`-- utility processes
```

or:

```text
Visual Studio Code.app
|-- Electron main process
|-- renderer
|-- extension host
`-- helpers
```

A family is ranked as one workload, but every process is independently reverified immediately before mutation and restoration.

## Candidate significance and ranking

### Minimum significance

A family must initially contribute at least:

```text
max(256 MB, 5% of physical RAM)
```

to qualify.

For an 8 GB machine, the effective threshold is about 410 MB.

This prevents tiny workloads from being penalized merely because the candidate list is short.

### Ranking signals

Primary signal:

- total resident memory of the verified family.

Additional positive ranking factors:

- positive resident-memory growth;
- longer sustained-background duration;
- multiple memory-heavy child processes;
- lack of recent user interaction.

Negative ranking factors:

- stable memory footprint;
- recently leaving the foreground;
- relatively small memory footprint.

The ranking algorithm must be deterministic and unit-tested. It must not use a machine-learning or opaque adaptive heuristic.

### Maximum managed set

At most the top 3 qualifying process families may be managed at once.

If fewer than 3 families qualify, only the qualifying families are managed.

## Intervention behavior

### Entry into intervention

When memory state becomes High or Critical:

1. build the verified candidate list;
2. rank families deterministically;
3. select at most the top 3;
4. reverify every candidate process immediately before mutation;
5. persist exact original scheduling state;
6. only after successful persistence, apply the approved policy;
7. verify the new state;
8. publish status to the dashboard and recovery state.

If recovery state cannot be persisted, that process is not mutated.

### CPU scheduling policy

The approved CPU policy is a fixed target of nice `+5`.

The manager must never increase a process's priority relative to its current state.

Examples:

| Original nice | Target | Result |
| ---: | ---: | --- |
| 0 | +5 | apply +5 |
| +2 | +5 | apply +5 |
| +8 | +5 | leave unchanged at +8 |
| -5 | +5 | apply +5 if otherwise eligible |

Every changed process is restored to its exact original nice value, not blindly to zero.

### I/O/background policy

CPU deprioritization is always the fallback intervention when the process is eligible and the state is safely persisted.

Additional `taskpolicy`-based background/I/O treatment is allowed only if a Catalina calibration proves all of the following for an existing disposable process:

```text
capture original policy
        |
        v
apply background / I/O policy
        |
        v
verify applied state
        |
        v
restore original policy
        |
        v
verify exact restoration
```

If any step cannot be proven reliably on Catalina 10.15.7, production I/O policy remains Unsupported and Memory Management uses nice `+5` only.

The implementation must not infer a restoration command from behavior on newer macOS versions.

## Dynamic managed-set replacement

A managed family that becomes the foreground application must be restored immediately before another family can replace it.

Example:

```text
1. Firefox       1.8 GB
2. VS Code       1.3 GB
3. Discord       700 MB
```

If Firefox becomes foreground:

```text
restore Firefox first
        |
        v
remove Firefox from managed set
        |
        v
re-rank remaining candidates
        |
        v
optionally admit candidate #4
```

A family that becomes the configured App Priority target follows the same restore-first rule.

If a managed process exits, its record remains only as historical session evidence. A reused PID is never mutated or restored.

## Restoration behavior

### Healthy recovery

After five consecutive Healthy samples:

1. stop admitting new candidates;
2. reverify every managed process;
3. restore exact original nice values;
4. restore calibrated I/O policy where supported;
5. verify restoration;
6. clear only resolved recovery records.

### Performance Mode OFF

Performance Mode OFF overrides the hysteresis timer and immediately begins restoration of all valid managed processes.

The same restoration logic is used by:

- normal Performance Mode OFF;
- Emergency Restore;
- failed Performance Mode activation;
- stale-session recovery after CatalinaPerformance relaunch.

### Partial restore failure

If some processes restore and one cannot be safely verified:

- successfully restored records are resolved;
- the unverifiable process is not touched;
- unresolved recovery evidence is retained;
- the dashboard reports incomplete restoration;
- Emergency Restore may retry later.

PID reuse, identity mismatch, or missing evidence means `do not touch`, not permission to guess.

## State persistence

Before changing a process, persist at least:

- PID;
- UID;
- parent/family identity;
- process start time;
- executable path;
- original nice value;
- applied nice value;
- original I/O/background policy, if supported;
- applied I/O/background policy, if supported;
- timestamp;
- family/application identity.

Persistence must be atomic and versioned.

If the active state cannot be saved, no mutation occurs.

### Launch/crash recovery

At application startup:

1. detect unresolved Memory Management state;
2. determine whether Performance Mode is still active;
3. reverify each recorded process identity;
4. restore valid surviving processes when appropriate;
5. never operate on reused PIDs;
6. retain unresolved evidence when exact restoration cannot be proven.

## Interaction with App Priority

A process or family can never simultaneously be an App Priority target and a Memory Management deprioritization target.

App Priority exclusion is applied before candidate ranking.

If a managed family later becomes the selected priority target:

1. restore its Memory Management policy first;
2. verify restoration;
3. remove it from the managed set;
4. only then allow App Priority to manage it.

## Interaction with Background Service Suppression

Memory Management does not duplicate Background Service Suppression.

At High or Critical pressure it may request a recheck of the already-approved suppression catalog, but:

- no new launch label becomes authorized;
- existing protected services remain protected;
- a category resumed because the user opened its associated application stays resumed;
- Memory Management cannot override the user's resume decision.

The existing Background Service Suppression coordinator remains authoritative for those workers.

## Failure handling

### Telemetry failure

Telemetry failure is fail-open.

If one or more signals become unavailable:

- unavailable is never converted to zero;
- classifier confidence is reduced;
- no new intervention begins unless enough other verified signals still satisfy the policy.

If classifier confidence becomes insufficient while intervention is already active:

- stop admitting new families;
- preserve recovery state;
- conservatively restore currently managed families.

### Mutation failure

If one family in a selected top-three set fails mutation, the manager does not continue down the ranking list indefinitely to replace it during the same decision cycle.

Example:

```text
Family A   Applied
Family B   Failed
Family C   Applied
```

The decision cycle remains limited to those three selected families.

### Critical pressure

Critical pressure does not increase the approved intervention strength. The dashboard may warn:

```text
Critical memory pressure persists.

3 background workloads are already deprioritized.
Swap-out activity remains elevated.

Consider closing an unused memory-heavy application.
```

## Advanced UI

Memory Pressure Management remains part of the one-switch Performance Mode model.

It should appear as an informational Advanced section, not a collection of user tuning sliders:

```text
Memory Pressure Management

Automatically active with Performance Mode.

Current state: Healthy
Automatic intervention: Ready
CPU deprioritization: nice +5
I/O deprioritization: Supported / Unsupported
Maximum managed workloads: 3

[ View Current Memory Details ]
```

The UI must not expose arbitrary user controls for:

- free-RAM targets;
- swap thresholds;
- compressor thresholds;
- nice level;
- maximum managed-family count.

Those are safety policy, not user tuning knobs.

The existing coarse Memory/Storage presentation should be reorganized so the new subsystem becomes the authoritative memory interpretation rather than creating contradictory duplicate states.

## Session Dashboard

Memory Management receives a dedicated `Memory / Swap` section, following the existing dedicated WindowServer presentation pattern.

### Active-session example

```text
Memory / Swap

State                         Healthy
Physical Used                 5.8 GB
Available                     2.2 GB
Compressed                    1.1 GB
Compression Growth            +18 MB/min

Swap Used                     412 MB
Swap Growth                   +0 MB/min
Swap In                       0 MB/min
Swap Out                      0 MB/min

Page-Out Activity             Low
Managed Workloads             0
```

### Active intervention example

```text
Memory / Swap

State                         High
Available                     540 MB
Compressed                    2.4 GB
Compression Growth            +216 MB/min
Swap Used                     1.3 GB
Swap Growth                   +148 MB/min
Swap Out                      +96 MB/min

Automatic Management          Active
Managed Workloads             3

Firefox                       1.7 GB   nice +5
VS Code                       1.2 GB   nice +5
Discord                       620 MB   nice +5

I/O Policy                    Active / Unsupported
```

The dashboard must distinguish:

- tracked families from managed families;
- current state from maximum session state;
- historical swap allocation from new swap growth;
- high RAM utilization from active VM contention.

### Completed-session evidence

A completed session should preserve at least:

- baseline memory state;
- maximum pressure state;
- baseline compressed memory;
- peak compressed memory;
- peak compression-growth rate;
- baseline swap;
- peak swap;
- net session swap growth;
- peak swap-in rate;
- peak swap-out rate;
- time Healthy;
- time Elevated;
- time High;
- time Critical;
- number of intervention episodes;
- families managed;
- longest intervention duration;
- restoration result.

The purpose is to determine whether management actually shortened or reduced memory-pressure episodes rather than merely proving that mutation code ran.

## Catalina capability checkpoint

Production implementation must stop at a read-only Catalina VM capability checkpoint before mutation logic is enabled.

The capability evidence must determine which telemetry counters are valid and what exact units/rates can be used safely.

A separate disposable-process calibration must prove `taskpolicy` capture/apply/verify/restore behavior before I/O deprioritization enters production.

If that calibration fails, I/O policy remains Unsupported and CPU nice `+5` remains the only automatic process intervention.

## Testing strategy

### Telemetry tests

Cover:

- cumulative counter delta calculations;
- elapsed-time rate calculations;
- counter rollback/reset;
- unavailable values;
- overflow protection;
- baseline handling;
- historical swap without growth.

### Classifier tests

Cover:

- one abnormal sample does not trigger;
- three Elevated candidates produce Elevated;
- three High candidates permit intervention;
- two Critical candidates produce Critical;
- five Healthy samples restore;
- Elevated/High/Critical resets the Healthy recovery counter;
- high historical swap with stable counters does not independently trigger;
- degraded telemetry does not fabricate zero values.

### Family analyzer tests

Cover:

- same-user grouping;
- verified process ancestry/application identity;
- three-sample background requirement;
- frontmost exclusion;
- App Priority exclusion;
- protected infrastructure exclusion;
- minimum significance threshold;
- deterministic ranking;
- maximum of three families;
- recently foregrounded family penalty;
- process-family memory aggregation.

### Mutation tests

Cover:

- nice 0 to +5;
- nice +2 to +5;
- existing +8 preserved;
- exact original-value restoration;
- persistence before mutation;
- restore before family replacement;
- immediate foreground restore;
- App Priority conflict restore;
- PID reuse refusal;
- partial family mutation failure;
- partial restoration failure.

### Persistence/recovery tests

Cover:

- atomic state save;
- schema/version handling;
- corrupted-state recovery;
- stale-session recovery;
- restart recovery;
- successful record cleanup;
- unresolved restore retention.

### Integration tests

Cover interaction with:

- Performance Mode ON/OFF;
- Emergency Restore;
- App Priority;
- Background Service Suppression;
- Session Dashboard persistence;
- failed activation paths.

## Catalina runtime validation

### Phase 1: capability only

No mutations.

- collect VM counters while idle;
- launch representative Firefox / development workloads;
- create moderate memory pressure in a controlled way;
- confirm counter direction and units;
- verify rate calculations;
- determine which signals are production-safe.

### Phase 2: controlled scheduling calibration

Use disposable test processes to prove:

- nice `+5` application;
- exact nice restoration;
- `taskpolicy` capture/apply/verify/restore if supported.

### Phase 3: real intervention

Create controlled memory pressure and verify:

```text
Healthy
-> Elevated
-> High
-> no more than 3 families managed
-> pressure recovery
-> 5 Healthy samples
-> exact restoration
```

Also verify:

- foregrounding a managed app restores it immediately;
- the App Priority target is never selected;
- Performance Mode OFF restores immediately;
- Emergency Restore works;
- stale-session recovery works after app relaunch.

### Phase 4: performance evidence

Compare repeated representative workloads and examine:

- swap growth;
- swap-out rate;
- compression growth;
- UI responsiveness;
- workload completion time;
- duration of High/Critical memory pressure.

If the feature merely redistributes scheduling without reducing pressure or improving responsiveness, the policy should be revised rather than assumed beneficial.

## Acceptance criteria

Memory Pressure & Swap Management 1.0 is complete only when all of the following are true:

1. Catalina VM telemetry sources have been capability-verified on macOS 10.15.7.
2. Unsupported metrics remain explicitly Unsupported.
3. The classifier reacts only to sustained multi-signal deterioration.
4. No automatic intervention occurs below High pressure.
5. Candidate families satisfy all eligibility and protection rules.
6. No more than 3 families are automatically managed at once.
7. Managed eligible processes use at most nice `+5` unless an existing worse nice value is preserved.
8. `taskpolicy` is used only if exact calibration and restoration are proven.
9. Foreground and App Priority conflicts restore before any replacement mutation.
10. Five consecutive Healthy samples restore exact original scheduling state.
11. Performance Mode OFF and Emergency Restore trigger immediate restoration.
12. PID reuse or identity mismatch never authorizes mutation or restoration.
13. Recovery state is persisted before mutation and unresolved state survives failures.
14. Dashboard reporting distinguishes high usage from active pressure and shows intervention evidence accurately.
15. No swap disabling, purge loop, app killing, daemon unloading, or VM/kernel tuning is introduced.
16. Hands-on Catalina runtime validation confirms apply, recovery, OFF, Emergency Restore, and stale-session behavior.

## Final design summary

Memory Pressure & Swap Management 1.0 is a Catalina-specific, multi-signal memory-pressure manager. It detects sustained virtual-memory contention, ranks verified noncritical background application families, temporarily applies nice `+5` and—only if Catalina calibration proves exact reversibility—background/I/O `taskpolicy` treatment to at most three families, and restores their exact original state after approximately 10 seconds of sustained Healthy conditions or immediately when user activity or safety conditions require it.

The subsystem deliberately avoids application termination, swap disabling, memory purging, and VM/kernel manipulation.
