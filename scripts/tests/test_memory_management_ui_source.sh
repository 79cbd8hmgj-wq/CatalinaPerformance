#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MAIN="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift"
PANEL="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/MemoryManagementPanelController.swift"
DASHBOARD="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift"

for file in "$MAIN" "$PANEL" "$DASHBOARD"; do
    test -f "$file"
done

grep -F 'import CatalinaPerformanceMemoryCore' "$MAIN" >/dev/null
grep -F 'section("Memory Pressure Management"' "$MAIN" >/dev/null
grep -F 'configureMemoryManagementStatusUpdates()' "$MAIN" >/dev/null
grep -F 'updateMemoryManagementStatus(' "$MAIN" >/dev/null
grep -F 'memoryManagementStatus(from:' "$MAIN" >/dev/null
grep -F 'Memory Pressure Management automatically watches sustained VM contention' "$MAIN" >/dev/null

grep -F 'final class MemoryManagementPanelController' "$PANEL" >/dev/null
grep -F 'Automatically active with Performance Mode.' "$PANEL" >/dev/null
grep -F 'CPU deprioritization: nice +5' "$PANEL" >/dev/null
grep -F 'Maximum managed workloads: 3' "$PANEL" >/dev/null
grep -F 'I/O deprioritization: Unsupported on this Catalina target' "$PANEL" >/dev/null
grep -F 'Managed workloads:' "$PANEL" >/dev/null

! grep -E 'NSSlider|NSStepper|killall|SIGKILL|taskpolicy|purge|swapfile|sysctl[[:space:]]+-w' "$PANEL" >/dev/null

grep -F 'section(title: "Memory / Swap"' "$DASHBOARD" >/dev/null
grep -F 'makeMemoryAwareViewModel' "$DASHBOARD" >/dev/null

printf 'PASS: Memory Management Advanced UI source contract\n'
