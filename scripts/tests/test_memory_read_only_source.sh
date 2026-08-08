#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PACKAGE="$ROOT/app/CatalinaPerformance/Package.swift"
MEMORY_CORE="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceMemoryCore"
DASHBOARD="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/MemorySessionDashboardPresentation.swift"
PACKAGE_SCRIPT="$ROOT/scripts/package_app.sh"
ON_WRAPPER="$ROOT/scripts/performance_on_with_priority.sh"
OFF_WRAPPER="$ROOT/scripts/performance_off_with_priority.sh"
EMERGENCY_WRAPPER="$ROOT/scripts/emergency_restore_with_priority.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$MEMORY_CORE/MemoryTelemetryCollector.swift" ] || fail "Memory telemetry collector is missing"
[ -f "$MEMORY_CORE/MemoryPressureClassifier.swift" ] || fail "Memory pressure classifier is missing"
[ -f "$DASHBOARD" ] || fail "Memory / Swap dashboard presentation is missing"

if grep -q 'CatalinaPerformanceMemoryAgent' "$PACKAGE" "$PACKAGE_SCRIPT" "$ON_WRAPPER" "$OFF_WRAPPER" "$EMERGENCY_WRAPPER"; then
    fail "Memory Agent is still present in the production package or lifecycle"
fi

if grep -q 'memory_management_wrapper_common' "$PACKAGE_SCRIPT" "$ON_WRAPPER" "$OFF_WRAPPER" "$EMERGENCY_WRAPPER"; then
    fail "Memory mutation wrapper dependency is still present"
fi

if grep -R -E -q 'MemoryAgentService|MemoryInterventionController|MemoryDesiredStateStore|requestedNiceValue|setpriority\(|taskpolicy' "$MEMORY_CORE"; then
    fail "MemoryCore still contains a mutation path"
fi

for label in 'Managed Workloads' 'I/O Policy' 'Intervention Episodes' 'Managed Families' 'Longest Intervention'; do
    if grep -q "$label" "$DASHBOARD"; then
        fail "Intervention-only dashboard row is still present: $label"
    fi
done

if grep -q 'nice +5\|depriorit\|automatic intervention' "$DASHBOARD"; then
    fail "Memory / Swap dashboard still describes automatic mutation"
fi

echo "PASS: Memory / Swap production path is read-only"
