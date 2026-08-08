#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WINDOW="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift"
MAIN="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift"
PACKAGE="$ROOT/scripts/package_app.sh"
MODELS="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift"
PRESENTATION="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift"
MEMORY_PRESENTATION="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/MemorySessionDashboardPresentation.swift"
MEMORY_AGGREGATE="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/MemorySessionAggregate.swift"
CORE="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore"

for file in "$WINDOW" "$MAIN" "$PACKAGE" "$MODELS" "$PRESENTATION" "$MEMORY_PRESENTATION" "$MEMORY_AGGREGATE"; do
    test -f "$file"
done

grep -F 'final class SessionDashboardWindowController: NSWindowController, NSWindowDelegate' "$WINDOW" >/dev/null
grep -F 'section(title: "Memory / Swap"' "$WINDOW" >/dev/null
grep -F 'viewModel.memoryRows' "$WINDOW" >/dev/null
grep -F 'makeMemoryAwareViewModel' "$WINDOW" >/dev/null
grep -F 'section(title: "Graphics / WindowServer"' "$WINDOW" >/dev/null
grep -F 'View Session Dashboard' "$MAIN" >/dev/null
grep -F 'prepareForOn' "$MAIN" >/dev/null
grep -F 'prepareForFinalization' "$MAIN" >/dev/null

grep -F 'Sources/CatalinaPerformance/SessionDashboardWindowController.swift' "$PACKAGE" >/dev/null
grep -F 'Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift' "$PACKAGE" >/dev/null
! grep -F 'CatalinaPerformanceMemoryAgent' "$PACKAGE" >/dev/null

grep -F 'public var memory: MemorySessionAggregate?' "$MODELS" >/dev/null
! grep -F 'value.map(Double.init)' "$MODELS" >/dev/null
grep -F 'value.map { Double($0) }' "$MODELS" >/dev/null

grep -F 'func makeMemoryAwareViewModel' "$MEMORY_PRESENTATION" >/dev/null
for label in '"State"' '"Physical Used"' '"Available"' '"Compressed"' '"Compression Growth"' '"Swap Used"' '"Swap Growth"' '"Swap In"' '"Swap Out"' '"Page-Out Activity"'; do
    grep -F "$label" "$MEMORY_PRESENTATION" >/dev/null
done
grep -F 'Allocated swap is not the same as active swap growth.' "$MEMORY_PRESENTATION" >/dev/null
grep -F 'A lower or higher endpoint alone is not proof of improved performance.' "$MEMORY_PRESENTATION" >/dev/null
! grep -F '"Managed Workloads"' "$MEMORY_PRESENTATION" >/dev/null
! grep -F '"Managed Families"' "$MEMORY_PRESENTATION" >/dev/null
! grep -F '"Intervention Episodes"' "$MEMORY_PRESENTATION" >/dev/null
! grep -F '"Longest Intervention"' "$MEMORY_PRESENTATION" >/dev/null
! grep -F '"Restoration"' "$MEMORY_PRESENTATION" >/dev/null
! grep -F '"I/O Policy"' "$MEMORY_PRESENTATION" >/dev/null

grep -F 'public struct MemorySessionAggregate' "$MEMORY_AGGREGATE" >/dev/null

if grep -R -nE 'killall[[:space:]]+WindowServer|pkill.*WindowServer|renice.*WindowServer|defaults[[:space:]]+write.*WindowServer' "$CORE" "$WINDOW"; then
    echo 'FAIL: WindowServer telemetry contains a prohibited mutation path' >&2
    exit 1
fi

printf 'PASS: Session Dashboard UI source contract\n'
