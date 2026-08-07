#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
COLLECTOR="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift"
PRODUCTION="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/ProductionSessionMetricsCollector.swift"
SESSION="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift"
FRONTMOST="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/MemoryFrontmostApplicationObserver.swift"
PACKAGE="$ROOT/scripts/package_app.sh"
COMMON="$ROOT/scripts/lib/memory_management_wrapper_common.sh"

for file in "$COLLECTOR" "$PRODUCTION" "$SESSION" "$FRONTMOST" "$PACKAGE" "$COMMON"; do
    test -f "$file"
done

grep -F 'MemoryManagementCoordinatorProviding' "$COLLECTOR" >/dev/null
grep -F 'memoryManagementCoordinatorForSession' "$COLLECTOR" >/dev/null
grep -F 'MemoryManagementCoordinator(' "$PRODUCTION" >/dev/null
grep -F 'MemoryDesiredStateStore(directoryURL: desiredStateDirectory)' "$PRODUCTION" >/dev/null
grep -F 'DarwinMemoryTelemetryCollector()' "$PRODUCTION" >/dev/null
grep -F 'MemoryFrontmostApplicationObserver(' "$PRODUCTION" >/dev/null
grep -F '(collector as? MemoryManagementCoordinatorProviding)?.memoryManagementCoordinatorForSession' "$SESSION" >/dev/null

grep -F 'NSWorkspace.didActivateApplicationNotification' "$FRONTMOST" >/dev/null
grep -F 'updateFrontmostApplication' "$FRONTMOST" >/dev/null
grep -F 'bundleIdentifier' "$FRONTMOST" >/dev/null
grep -F 'executableURL' "$FRONTMOST" >/dev/null

grep -F 'MEMORY_AGENT_NAME="CatalinaPerformanceMemoryAgent"' "$PACKAGE" >/dev/null
grep -F 'swift build --product "$MEMORY_AGENT_NAME"' "$PACKAGE" >/dev/null
grep -F 'install -m 755 "$BUILT_MEMORY_AGENT" "$BIN_DIR/$MEMORY_AGENT_NAME"' "$PACKAGE" >/dev/null
grep -F 'memory_management_wrapper_common.sh' "$PACKAGE" >/dev/null

grep -F 'CatalinaPerformanceMemoryAgent' "$COMMON" >/dev/null
grep -F '[ -z "$MEMORY_DESIRED_STATE" ] && return 0' "$COMMON" >/dev/null
! grep -E 'LaunchDaemon|launchctl[[:space:]]+(bootstrap|load)|taskpolicy|purge|swapfile|sysctl[[:space:]]+-w' "$COMMON" >/dev/null

printf 'PASS: Memory Management production wiring source contract\n'
