# Catalina 10.15.7 Memory taskpolicy Review — 2026-08-07

Target: macOS Catalina 10.15.7 build 19H15, Intel x86_64.

## Evidence

The Memory Management taskpolicy source-safety contract passed on the target Mac:

```text
PASS: Memory taskpolicy calibration source contract
```

The runtime calibration then stopped at its capability check with:

```text
/usr/bin/taskpolicy is unavailable.
```

Because the executable is unavailable on the target Catalina installation, CatalinaPerformance cannot prove the required capture -> apply -> verify -> exact restore -> verify-restored sequence for taskpolicy.

## Production decision

- `CatalinaMemoryCapabilities.current.taskPolicy` remains `false`.
- Memory Pressure & Swap Management 1.0 does not invoke `taskpolicy` in production.
- Dashboard/Advanced reporting must present I/O policy as **Unsupported** on this target profile.
- Automatic intervention remains limited to the approved reversible nice `+5` scheduling policy.
- No replacement private API, newer-macOS command, permanent helper, LaunchDaemon, kernel control, or undocumented I/O-priority mechanism is substituted.

## Related validation finding

The same target-Mac run exposed a linker regression because two C translation units both defined `cp_read_vm_memory_info`. That issue is independent of the taskpolicy capability result. The implementation branch now retains one canonical VM implementation, and the Catalina process-support source contract requires the symbol to be implemented by exactly one C translation unit.

This taskpolicy result is a capability result, not a failure of the core Memory Management feature. I/O treatment may be reconsidered only if a future Catalina-compatible mechanism can prove exact state capture and restoration under the same safety requirements.
