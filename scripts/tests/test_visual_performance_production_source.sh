#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
MAIN="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift"
CORE="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceVisualPerformanceCore"
APP="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance"
SEQUENCE="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceCore/ScriptSequenceCoordinator.swift"
FOREGROUND="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceCore/ForegroundSession.swift"
PACKAGE="$ROOT/scripts/package_app.sh"
DASHBOARD="$APP/SessionDashboardWindowController.swift"
LEGACY_APPLY="$ROOT/scripts/ui_responsiveness_apply.sh"
LEGACY_RESTORE="$ROOT/scripts/ui_responsiveness_restore.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "missing required file: $1"
}

for file in \
    "$CORE/CatalinaVisualPerformanceCatalog.swift" \
    "$CORE/VisualPerformanceCoordinator.swift" \
    "$CORE/VisualPerformanceModels.swift" \
    "$CORE/VisualPerformanceRestoreDecision.swift" \
    "$CORE/VisualPerformanceStateStore.swift" \
    "$APP/VisualPerformanceDefaultsOperator.swift" \
    "$APP/VisualPerformanceLifecycleController.swift" \
    "$APP/VisualPerformancePanelController.swift" \
    "$APP/VisualPerformanceDashboardAdapter.swift" \
    "$APP/LegacyUIResponsivenessRecovery.swift" \
    "$ROOT/docs/VISUAL_PERFORMANCE.md"
do
    require_file "$file"
done

for token in \
    finderAnimations \
    dockLaunchAnimation \
    missionControlTransitions \
    windowOpeningAnimations \
    reduceMotion \
    reduceTransparency \
    minimizeEffect \
    dockAutoHideDelay \
    dockAutoHideAnimation
do
    grep -q "$token" "$CORE/CatalinaVisualPerformanceCatalog.swift" || \
        fail "catalog is missing $token"
done

catalog_count=$(grep -c 'VisualSettingCatalogEntry(' "$CORE/CatalinaVisualPerformanceCatalog.swift")
[ "$catalog_count" -eq 9 ] || fail "expected 9 catalog entries, found $catalog_count"

grep -q 'applicability: .dockAutoHideEnabled' "$CORE/CatalinaVisualPerformanceCatalog.swift" || \
    fail 'conditional Dock settings are missing'
grep -q 'isDockAutoHideEnabled' "$APP/VisualPerformanceDefaultsOperator.swift" || \
    fail 'Dock auto-hide applicability is not read'

aggregate_guard_count=$(grep -c 'aggregateStatus == .recoveryRequired || aggregateStatus == .partiallyRestored' "$CORE/VisualPerformanceModels.swift")
[ "$aggregate_guard_count" -ge 2 ] || \
    fail 'aggregate recovery state is not authoritative for active records and snapshots'

grep -q 'executablePath:' "$APP/VisualPerformanceDefaultsOperator.swift" || \
    fail 'typed defaults executable boundary is missing'
grep -q '/usr/bin/defaults' "$APP/VisualPerformanceDefaultsOperator.swift" || \
    fail 'typed defaults path is missing'
if grep -Eq '/bin/(ba)?sh|osascript|sudo|killall|launchctl' "$APP/VisualPerformanceDefaultsOperator.swift"; then
    fail 'visual defaults boundary contains an unapproved execution path'
fi

for token in \
    'import CatalinaPerformanceVisualPerformanceCore' \
    'visualPerformanceLifecycleController.prepareForPerformanceOn' \
    'reason: .onRollback' \
    'PerformanceSequenceFactory.performanceOffCore()' \
    'reason: .normalOff' \
    'reason: .emergencyRestore' \
    'VisualPerformancePanelController' \
    'presentCurrentVisualSettings'
do
    grep -q "$token" "$MAIN" || fail "main lifecycle is missing: $token"
done

python3 - "$SEQUENCE" "$FOREGROUND" <<'PYINNER'
from pathlib import Path
import re
import sys

sequence = Path(sys.argv[1]).read_text(encoding='utf-8')
foreground = Path(sys.argv[2]).read_text(encoding='utf-8')
match = re.search(r'public enum PerformanceSequenceFactory.*?\n\}', sequence, re.S)
if match is None:
    raise SystemExit('FAIL: PerformanceSequenceFactory could not be isolated')
factory = match.group(0)
for token in ('.uiApply', '.uiRestore'):
    if token in factory:
        raise SystemExit('FAIL: new Performance Mode sequence still uses ' + token)
serialized = re.search(r'public var serializedEnvironment: String \{.*?\n    \}', foreground, re.S)
if serialized is None:
    raise SystemExit('FAIL: Foreground serializedEnvironment could not be isolated')
for token in ('DISABLE_FINDER_ANIMATIONS', 'SHORTEN_DOCK_ANIMATIONS', 'DISABLE_WINDOW_ANIMATIONS'):
    if token in serialized.group(0):
        raise SystemExit('FAIL: app-closing preferences still own visual setting ' + token)
PYINNER

grep -q -- '--legacy-test' "$LEGACY_APPLY" || \
    fail 'legacy UI apply is not production-guarded'
grep -q 'Legacy UI responsiveness apply is disabled' "$LEGACY_APPLY" || \
    fail 'legacy UI apply refusal is missing'
grep -q 'legacy_ui_state=' "$LEGACY_RESTORE" || \
    fail 'legacy restore state output is missing'
grep -q 'legacy_ui_pending_count=' "$LEGACY_RESTORE" || \
    fail 'legacy restore pending-count output is missing'

grep -q 'visualRestoreIsIncomplete' "$DASHBOARD" || \
    fail 'completed dashboard does not include Visual Performance restore status'
grep -q 'row.label != "UI Responsiveness"' "$DASHBOARD" || \
    fail 'obsolete legacy UI Responsiveness dashboard row is still displayed'

for file in \
    VisualPerformanceDefaultsOperator.swift \
    VisualPerformanceLifecycleController.swift \
    VisualPerformancePanelController.swift \
    VisualPerformanceDashboardAdapter.swift \
    LegacyUIResponsivenessRecovery.swift \
    CatalinaVisualPerformanceCatalog.swift \
    VisualPerformanceCoordinator.swift
do
    grep -q "$file" "$PACKAGE" || fail "package_app.sh does not require $file"
done

if grep -REn 'killall|SIGKILL|WindowServer.*terminate|Dock.*terminate|Finder.*terminate' \
    "$CORE" "$APP/VisualPerformanceDefaultsOperator.swift" \
    "$APP/VisualPerformanceLifecycleController.swift" \
    "$APP/VisualPerformancePanelController.swift" \
    "$APP/VisualPerformanceDashboardAdapter.swift"; then
    fail 'Visual Performance contains a prohibited forced refresh or termination path'
fi

printf 'PASS: Visual Performance production source contract\n'
