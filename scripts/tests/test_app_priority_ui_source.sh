#!/bin/sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." 2>/dev/null && pwd -P)
PANEL="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/AppPriorityPanelController.swift"
MAIN="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift"
FOREGROUND="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/ForegroundSessionPanelController.swift"
PACKAGE="$ROOT/scripts/package_app.sh"
AGENT_SERVICE="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformancePriorityCore/AppPriorityAgentService.swift"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[ -f "$PANEL" ] || fail "AppPriorityPanelController.swift is missing"
grep -F 'Boost one selected app while Performance Mode is ON' "$PANEL" >/dev/null || fail "enabled checkbox title missing"
grep -F 'Nice -5' "$PANEL" >/dev/null || fail "Nice -5 copy missing"
! grep -F 'Apply Priority Boost Now — Not implemented yet' "$MAIN" >/dev/null || fail "disabled App Priority placeholder remains"
grep -F 'performance_on_with_priority.sh' "$MAIN" >/dev/null || fail "Performance ON wrapper not wired"
grep -F 'performance_off_with_priority.sh' "$MAIN" >/dev/null || fail "Performance OFF wrapper not wired"
grep -F 'emergency_restore_with_priority.sh' "$MAIN" >/dev/null || fail "Emergency Restore wrapper not wired"
grep -F 'CATALINA_PERFORMANCE_PRIORITY_SELECTION_FILE' "$MAIN" >/dev/null || fail "priority selection environment missing"
grep -F 'CATALINA_PERFORMANCE_STATE_DIR' "$MAIN" >/dev/null || fail "explicit state environment missing"
grep -F 'CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH' "$MAIN" >/dev/null || fail "priority agent environment missing"
grep -F 'performanceModeIsOn: isOn' "$MAIN" >/dev/null || fail "Performance Mode state is not propagated to App Priority UI"
grep -F 'prioritySelectionProvider' "$FOREGROUND" >/dev/null || fail "priority conflict provider missing"
grep -F 'validateForegroundAddition' "$FOREGROUND" >/dev/null || fail "foreground conflict validation missing"
! grep -n 'excludedBundleIdentifiers' "$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformancePriorityCore/AppPriorityModels.swift" | grep -i 'terminal' >/dev/null || fail "Terminal must remain eligible"

[ -f "$AGENT_SERVICE" ] || fail "AppPriorityAgentService.swift is missing"
! grep -F '/usr/bin/nohup' "$AGENT_SERVICE" >/dev/null || fail "Darwin nohup must not launch the priority monitor"
grep -F 'process.executableURL = URL(fileURLWithPath: agentPath)' "$AGENT_SERVICE" >/dev/null || fail "priority monitor must launch the packaged agent directly"

[ -f "$PACKAGE" ] || fail "package_app.sh is missing"
for token in \
    'CatalinaPerformancePriorityAgent' \
    'Contents/Resources/bin' \
    'Contents/Resources/scripts' \
    'performance_on_with_priority.sh' \
    'performance_off_with_priority.sh' \
    'emergency_restore_with_priority.sh' \
    'app_priority_wrapper_common.sh'
do
    grep -F "$token" "$PACKAGE" >/dev/null || fail "package_app.sh is missing $token"
done
printf 'PASS: App Priority UI source contract\n'
