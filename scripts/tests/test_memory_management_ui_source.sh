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
grep -F 'Memory / Swap' "$PANEL" >/dev/null
grep -F 'Read-only monitoring.' "$PANEL" >/dev/null
grep -F 'does not change process priority, I/O policy, applications, swap, or VM settings' "$PANEL" >/dev/null
grep -F 'MemoryManagementStatusSnapshot?' "$PANEL" >/dev/null
grep -F 'PerformanceSessionStore' "$PANEL" >/dev/null

grep -F 'MemoryManagementPanelController()' "$PRIORITY_PANEL" >/dev/null
grep -F 'memoryManagementPanelController.makeControls()' "$PRIORITY_PANEL" >/dev/null

! grep -E 'nice[[:space:]]*\+?5|deprioritiz|Managed workloads|Maximum managed workloads|Automatic intervention|taskpolicy|renice|killall|SIGKILL|purge|swapfile|sysctl[[:space:]]+-w' "$PANEL" >/dev/null

grep -F 'section(title: "Memory / Swap"' "$DASHBOARD" >/dev/null
grep -F 'makeMemoryAwareViewModel' "$DASHBOARD" >/dev/null

printf 'PASS: Memory / Swap read-only UI source contract\n'
