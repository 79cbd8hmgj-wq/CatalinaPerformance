#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CORE="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore"
APP="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance"
MODELS="$CORE/WindowServerPressureModels.swift"
COLLECTOR="$CORE/WindowServerMetricsCollector.swift"
PRODUCTION="$CORE/ProductionSessionMetricsCollector.swift"
COORDINATOR="$CORE/PerformanceSessionCoordinator.swift"
PRESENTER="$CORE/SessionDashboardPresentation.swift"
WINDOW="$APP/SessionDashboardWindowController.swift"
DOC="$ROOT/docs/WINDOWSERVER_GPU_PRESSURE_RUNTIME_CHECKLIST.md"

for file in "$MODELS" "$COLLECTOR" "$PRODUCTION" "$COORDINATOR" "$PRESENTER" "$WINDOW" "$DOC"; do
    test -f "$file"
done

grep -F 'case normal' "$MODELS" >/dev/null
grep -F 'case elevated' "$MODELS" >/dev/null
grep -F 'case high' "$MODELS" >/dev/null
grep -F 'case unavailable' "$MODELS" >/dev/null
grep -F 'elevatedAbsoluteThreshold = 15.0' "$MODELS" >/dev/null
grep -F 'highAbsoluteThreshold = 30.0' "$MODELS" >/dev/null
grep -F 'elevatedDeltaThreshold = 8.0' "$MODELS" >/dev/null
grep -F 'highDeltaMinimumCPU = 20.0' "$MODELS" >/dev/null
grep -F 'highDeltaThreshold = 12.0' "$MODELS" >/dev/null
grep -F 'requiredHighCandidateCount = 2' "$MODELS" >/dev/null
grep -F 'rollingCPUValues.count > 3' "$MODELS" >/dev/null
grep -F 'validCPUPercent' "$MODELS" >/dev/null

grep -F 'process.processName == "WindowServer"' "$COLLECTOR" >/dev/null
grep -F 'process.executablePath.hasSuffix("/WindowServer")' "$COLLECTOR" >/dev/null
grep -F 'cpuTimeNanoseconds' "$COLLECTOR" >/dev/null
grep -F 'date.timeIntervalSince(previous.capturedAt)' "$COLLECTOR" >/dev/null
grep -F 'WindowServer process identity changed; a fresh CPU baseline is required.' "$COLLECTOR" >/dev/null
! grep -F 'ps ' "$COLLECTOR" >/dev/null
! grep -F 'Timer.' "$COLLECTOR" >/dev/null
! grep -F 'DispatchSource' "$COLLECTOR" >/dev/null

grep -F 'let windowServerCollector = WindowServerMetricsCollector(' "$PRODUCTION" >/dev/null
grep -F 'windowServerCollector: windowServerCollector' "$PRODUCTION" >/dev/null

grep -F 'graphicsBaselineSampleCount = 3' "$COORDINATOR" >/dev/null
grep -F 'graphicsBaselineInterval: TimeInterval = 2.0' "$COORDINATOR" >/dev/null
grep -F 'Measuring graphics baseline…' "$COORDINATOR" >/dev/null
grep -F 'Graphics baseline is unavailable; Performance Mode can continue.' "$COORDINATOR" >/dev/null

grep -F 'WindowServer load remained within the expected range.' "$PRESENTER" >/dev/null
grep -F 'WindowServer load was elevated during this session. No additional graphics changes were made automatically.' "$PRESENTER" >/dev/null
grep -F 'Sustained WindowServer pressure was detected.' "$PRESENTER" >/dev/null
grep -F 'Graphics pressure was elevated before Performance Mode started.' "$PRESENTER" >/dev/null
grep -F 'section(title: "Graphics / WindowServer"' "$WINDOW" >/dev/null

grep -F 'WindowServer monitoring causes no administrator authorization prompt.' "$DOC" >/dev/null
grep -F 'Missing, invalid, or ambiguous telemetry displays **Unavailable**, never `0%`.' "$DOC" >/dev/null

if grep -R -nE 'killall[[:space:]]+WindowServer|pkill[^\n]*WindowServer|renice[^\n]*WindowServer|defaults[[:space:]]+write[^\n]*WindowServer|launchctl[^\n]*(bootout|disable)[^\n]*WindowServer' "$CORE" "$WINDOW"; then
    echo 'FAIL: WindowServer telemetry contains a prohibited mutation path' >&2
    exit 1
fi

if grep -R -nE 'NSAppleScript|administrator privileges|AuthorizationExecuteWithPrivileges' "$MODELS" "$COLLECTOR" "$PRODUCTION"; then
    echo 'FAIL: WindowServer telemetry contains an authorization path' >&2
    exit 1
fi

printf 'PASS: WindowServer pressure source contract\n'
