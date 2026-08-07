#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
OBSERVER="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceActivityObserver.swift"
PANEL="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/BackgroundServiceSuppressionPanelController.swift"
MAIN="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift"
PACKAGE="$ROOT/scripts/package_app.sh"
SWIFT_PACKAGE="$ROOT/app/CatalinaPerformance/Package.swift"
MODELS="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceModels.swift"
STATE_STORE="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceStateStore.swift"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { grep -F "$1" "$2" >/dev/null 2>&1 || fail "missing source: $1"; }
assert_not_contains() { if grep -F "$1" "$2" >/dev/null 2>&1; then fail "prohibited source: $1"; fi; }

[ -f "$SWIFT_PACKAGE" ] || fail "Swift package manifest missing"
assert_contains 'name: "CatalinaPerformanceBackgroundServicesCore"' "$SWIFT_PACKAGE"
assert_contains '"CatalinaPerformanceBackgroundServicesCore"' "$SWIFT_PACKAGE"
[ -f "$MODELS" ] || fail "background service models missing"
[ -f "$STATE_STORE" ] || fail "background service state store missing"

[ -f "$OBSERVER" ] || fail "activity observer missing"
assert_contains 'NSWorkspace.didLaunchApplicationNotification' "$OBSERVER"
assert_contains 'NSWorkspace.didActivateApplicationNotification' "$OBSERVER"
assert_contains 'runningApplication.bundleIdentifier' "$OBSERVER"
assert_contains 'resume(category:' "$OBSERVER"
assert_not_contains 'localizedCaseInsensitiveContains' "$OBSERVER"
assert_not_contains 'contains("Photos")' "$OBSERVER"
assert_not_contains 'killall' "$OBSERVER"

[ -f "$PANEL" ] || fail "background service suppression panel missing"
assert_contains 'Background Service Suppression' "$PANEL"
assert_contains 'Automatic while Performance Mode is ON' "$PANEL"
assert_contains 'macOS automatic updates' "$PANEL"
assert_contains 'App Store background updates' "$PANEL"
assert_contains 'Photos background workers' "$PANEL"
assert_contains 'Mail background workers' "$PANEL"
assert_contains 'Messages and FaceTime workers' "$PANEL"
assert_contains 'Siri, Dictation, and speech workers' "$PANEL"
assert_contains 'Pause iCloud Drive synchronization while Performance Mode is ON' "$PANEL"
assert_contains 'Protected: iCloud Keychain, Safari passwords, AirDrop, networking, diagnostics, crash reporting, and essential macOS services' "$PANEL"
assert_contains 'setInteractionState(actionsEnabled: Bool, performanceModeIsOn: Bool)' "$PANEL"
assert_contains 'actionsEnabled && !performanceModeIsOn' "$PANEL"

assert_contains 'advanced.pauseICloudDriveWhileOn' "$MAIN"
assert_contains 'PAUSE_ICLOUD_DRIVE_WHILE_ON=' "$MAIN"
assert_contains 'backgroundServicePanelController' "$MAIN"

assert_contains 'backgroundServiceSuppressionCoordinator' "$MAIN"
assert_contains 'backgroundServiceActivityObserver' "$MAIN"
assert_contains 'prepareForPerformanceOn' "$MAIN"
assert_contains 'performanceOnSucceeded' "$MAIN"
assert_contains 'performanceOnFailed' "$MAIN"
assert_contains 'prepareForPerformanceOff' "$MAIN"
assert_contains 'performanceOffFinished' "$MAIN"
assert_contains 'recoverStaleSession' "$MAIN"
assert_contains 'backgroundServiceActivityObserver.start()' "$MAIN"
assert_contains 'backgroundServiceActivityObserver.stop()' "$MAIN"
assert_contains 'performanceSessionCoordinator.finalizationCompleted' "$MAIN"
assert_contains 'background_service_suppression' "$MAIN"
assert_contains 'CATALINA_PERFORMANCE_BACKGROUND_SERVICE_PUBLIC_STATUS_DIR' "$MAIN"
assert_contains 'background_service_status' "$MAIN"
assert_contains 'settings-status.json' "$MAIN"

[ -f "$PACKAGE" ] || fail "package script missing"
for packaged_script in \
    background_service_probe.sh \
    background_service_settings_apply.sh \
    background_service_settings_restore.sh \
    background_service_settings_status.sh; do
    assert_contains "$packaged_script" "$PACKAGE"
done
assert_contains 'lib/background_service_settings_common.sh' "$PACKAGE"
assert_contains 'lib/background_service_wrapper_common.sh' "$PACKAGE"
assert_not_contains 'catalina-10.15.7-service-probe' "$PACKAGE"

MUTATION_FILES="
$ROOT/scripts/background_service_settings_apply.sh
$ROOT/scripts/background_service_settings_restore.sh
$ROOT/scripts/background_service_settings_status.sh
$ROOT/scripts/lib/background_service_settings_common.sh
$ROOT/scripts/lib/background_service_wrapper_common.sh
$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceWorkerController.swift
$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceBackgroundServicesCore/BackgroundServiceSuppressionCoordinator.swift
"
for mutation_file in $MUTATION_FILES; do
    [ -f "$mutation_file" ] || fail "mutation file missing: $mutation_file"
    assert_not_contains 'killall' "$mutation_file"
    assert_not_contains 'SIGKILL' "$mutation_file"
    assert_not_contains 'launchctl disable' "$mutation_file"
    assert_not_contains 'launchctl bootout' "$mutation_file"
    if grep -E 'rm[[:space:]].*LaunchAgents' "$mutation_file" >/dev/null 2>&1; then
        fail "LaunchAgent deletion command present: $mutation_file"
    fi
    for protected_name in securityd trustd accountsd cloudd apsd sharingd mDNSResponder diagnosticd ReportCrash; do
        assert_not_contains "$protected_name" "$mutation_file"
    done
done

printf 'PASS: Background service UI source contract\n'
