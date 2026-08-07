#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PANEL="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/MemoryManagementPanelController.swift"
PRIORITY_PANEL="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/AppPriorityPanelController.swift"
DASHBOARD="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift"

for file in "$PANEL" "$PRIORITY_PANEL" "$DASHBOARD"; do
    test -f "$file"
done

grep -F 'final class MemoryManagementPanelController' "$PANEL" >/dev/null
grep -F 'Memory Pressure Management' "$PANEL" >/dev/null
grep -F 'Automatically active with Performance Mode.' "$PANEL" >/dev/null
grep -F 'CPU deprioritization: nice +5' "$PANEL" >/dev/null
grep -F 'Maximum managed workloads: 3' "$PANEL" >/dev/null
grep -F 'I/O deprioritization: Unsupported on this Catalina target' "$PANEL" >/dev/null
grep -F 'MemoryManagementStatusSnapshot?' "$PANEL" >/dev/null
grep -F 'PerformanceSessionStore' "$PANEL" >/dev/null

grep -F 'MemoryManagementPanelController()' "$PRIORITY_PANEL" >/dev/null
grep -F 'memoryManagementPanelController.makeControls()' "$PRIORITY_PANEL" >/dev/null

# Status-only UI: safety policy is not configurable here.
! grep -E 'NSSlider|NSStepper|nice(Level|Value)|family(Cap|Limit)|swap(Target|Limit)|compress(or|ion)(Target|Threshold)|vmThreshold' "$PANEL" >/dev/null
! grep -E 'killall|SIGKILL|taskpolicy|purge|swapfile|sysctl[[:space:]]+-w' "$PANEL" >/dev/null

grep -F 'section(title: "Memory / Swap"' "$DASHBOARD" >/dev/null
grep -F 'makeMemoryAwareViewModel' "$DASHBOARD" >/dev/null

printf 'PASS: Memory Management Advanced UI source contract\n'
