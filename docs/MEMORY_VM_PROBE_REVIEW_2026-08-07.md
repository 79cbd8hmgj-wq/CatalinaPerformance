# Catalina 10.15.7 Memory VM Probe Review — 2026-08-07

Target evidence: macOS Catalina 10.15.7 build 19H15, Darwin 19.6.0, Intel x86_64.

## Reviewed platform facts

- `hw.memsize` reports 4,294,967,296 bytes (4 GiB physical RAM).
- Hardware page size is 4,096 bytes.
- `vm.swapusage` is available and reported 1,024 MiB total / 96.5 MiB used during the probe.
- `vm_stat` exposes free, active, inactive, speculative, wired, purgeable, compressor occupancy, pages stored in compressor, compressions, decompressions, pageins, pageouts, swapins, and swapouts.
- `memory_pressure` exposes the same compressor and cumulative I/O counters, but its displayed capacity was 2 GiB while `hw.memsize` is 4 GiB. Therefore its displayed free-percentage/capacity basis is not used by production memory sizing.
- `vm.memory_pressure` exists and returned `0` in the normal sample. Nonzero semantics were not observed, so the native pressure state remains unsupported for automatic policy decisions in 1.0 until separately validated.
- `vm.page_free_target`, `vm.page_free_min`, and `vm.pageout_stat_now` are unavailable on this Catalina build and are not production dependencies.
- Compressor mode is `4`; this is diagnostic only and is never written.

## Counter behavior across the two 2-second intervals

Pressure-forward counters were stable in the idle/normal evidence:

- Compressions: 15,859,682 -> 15,859,682 -> 15,859,682.
- Pageouts: 35,921 -> 35,921 -> 35,921.
- Swapins: 571,122 -> 571,122 -> 571,122.
- Swapouts: 677,868 -> 677,868 -> 677,868.

Decompressions increased substantially while the pressure-forward counters stayed flat:

- 10,858,306 -> 10,860,178 -> 10,864,010.

Therefore decompression activity is explicitly not treated as evidence of memory pressure.

Compressor occupancy also decreased during the sample:

- 168,130 -> 167,851 -> 166,811 physical compressor pages.

At 4,096 bytes/page this is approximately 656.8 MiB -> 655.7 MiB -> 651.6 MiB, below the approved 20% compressed-memory threshold for a 4 GiB machine.

## Production capability decision

Enabled:

- compressed physical footprint from `compressor_page_count * pageSize`;
- cumulative compression counter;
- cumulative pageout counter;
- cumulative swapin/swapout counters;
- `vm.swapusage` current used bytes;
- physical/available memory from Mach host statistics plus `hw.memsize`.

Disabled/untrusted for automatic decisions:

- `memory_pressure` displayed capacity/free percentage;
- `vm.memory_pressure` state semantics beyond observed normal `0`;
- unavailable VM sysctls listed above;
- `taskpolicy` until its independent apply/verify/restore calibration.

## Rate-threshold decision

The normal probe showed exactly zero increments for compressions, pageouts, swapins, and swapouts across both measured intervals. For 1.0 these counters therefore use a reviewed positive-activity floor (`rate > 0`) only as corroborating evidence. Positive activity alone cannot authorize intervention: the classifier still requires approved low-available/compressed-memory combinations plus sustained High/Critical confirmation.

Repeated swap-used snapshots were not captured by this first probe, so no `swapGrowthBytesPerSecond` or swap-churn numeric threshold is approved yet. Those signals remain unavailable rather than guessed.

This profile is intentionally conservative and can be tightened only after controlled Catalina runtime pressure evidence is captured.
