#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WINDOW="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift"
MAIN="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift"
PACKAGE="$ROOT/scripts/package_app.sh"
MODELS="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift"
PRESENTATION="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionDashboardPresentation.swift"

test -f "$WINDOW"
grep -F 'final class SessionDashboardWindowController: NSWindowController, NSWindowDelegate' "$WINDOW" >/dev/null
grep -F 'setFrameAutosaveName("CatalinaPerformance.SessionDashboard")' "$WINDOW" >/dev/null
grep -F 'Refresh Now' "$WINDOW" >/dev/null
grep -F 'Last Completed Session' "$WINDOW" >/dev/null
grep -F 'Completed: ' "$WINDOW" >/dev/null
grep -F 'Restore result: ' "$WINDOW" >/dev/null
grep -F 'Unavailable' "$WINDOW" >/dev/null
grep -F 'func render(_ viewModel: SessionDashboardViewModel)' "$WINDOW" >/dev/null
grep -F 'Focused Firefox Targets' "$WINDOW" >/dev/null
grep -F 'viewModel.priorityDetailRows' "$WINDOW" >/dev/null
! grep -F 'row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true' "$WINDOW" >/dev/null
grep -F 'precondition(Thread.isMainThread)' "$WINDOW" >/dev/null
grep -F 'private func addFullWidthArrangedSubview(_ view: NSView)' "$WINDOW" >/dev/null
grep -F 'contentStack.addArrangedSubview(view)' "$WINDOW" >/dev/null
grep -F 'view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true' "$WINDOW" >/dev/null
! grep -F 'top.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true' "$WINDOW" >/dev/null
! grep -F 'stack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true' "$WINDOW" >/dev/null
! grep -F 'box.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true' "$WINDOW" >/dev/null
! grep -F 'row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true' "$WINDOW" >/dev/null
! grep -F 'Timer.scheduledTimer' "$WINDOW" >/dev/null
! grep -F 'osascript' "$WINDOW" >/dev/null
! grep -F 'administrator privileges' "$WINDOW" >/dev/null
! grep -F 'CatalinaPerformance.SessionDashboard' "$MAIN" >/dev/null
grep -F 'View Session Dashboard' "$MAIN" >/dev/null
grep -F 'prepareForOn' "$MAIN" >/dev/null
grep -F 'onSequenceCompleted(succeeded:' "$MAIN" >/dev/null
grep -F 'prepareForFinalization' "$MAIN" >/dev/null
grep -F 'finalizationCompleted(' "$MAIN" >/dev/null
grep -F 'commandEvidence:' "$MAIN" >/dev/null
grep -F 'recoverAtLaunch { [weak self]' "$MAIN" >/dev/null
grep -F 'isDashboardTransitionInProgress' "$MAIN" >/dev/null
grep -F 'beginDashboardWrappedAction' "$MAIN" >/dev/null
grep -F 'PerformanceSequenceFactory.performanceOn(featureEnabled:' "$MAIN" >/dev/null
grep -F 'PerformanceSequenceFactory.performanceOff(featureEnabled:' "$MAIN" >/dev/null
! grep -F 'session_dashboard.sh' "$MAIN" >/dev/null

test -f "$PACKAGE"
grep -F 'Sources/CatalinaPerformance/SessionDashboardWindowController.swift' "$PACKAGE" >/dev/null
grep -F 'Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift' "$PACKAGE" >/dev/null
grep -F 'Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift' "$PACKAGE" >/dev/null
grep -F 'Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift' "$PACKAGE" >/dev/null
grep -F 'Sources/CatalinaPerformanceDashboardCore/PerformanceSessionStore.swift' "$PACKAGE" >/dev/null
! grep -F 'session_dashboard.sh' "$PACKAGE" >/dev/null

test -f "$MODELS"
! grep -F 'value.map(Double.init)' "$MODELS" >/dev/null
grep -F 'value.map { Double($0) }' "$MODELS" >/dev/null
test -f "$PRESENTATION"
grep -F 'priorityDetailRows: [SessionDashboardMetricRow]' "$PRESENTATION" >/dev/null
grep -F 'Tracked Firefox Processes' "$PRESENTATION" >/dev/null
grep -F 'Processes Actually Boosted' "$PRESENTATION" >/dev/null
grep -F 'Waiting for stable active content process' "$PRESENTATION" >/dev/null
grep -F 'BackgroundServiceDashboardCategoryStatus' "$MODELS" >/dev/null
grep -F 'case backgroundServiceSuppression' "$MODELS" >/dev/null
grep -F 'replaceBackgroundServiceStatuses' "$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift" >/dev/null
grep -F 'macOS Updates' "$PRESENTATION" >/dev/null
grep -F 'App Store Updates' "$PRESENTATION" >/dev/null
grep -F 'Photos Workers' "$PRESENTATION" >/dev/null
grep -F 'Mail Workers' "$PRESENTATION" >/dev/null
grep -F 'Messages / FaceTime Workers' "$PRESENTATION" >/dev/null
grep -F 'Siri / Speech Workers' "$PRESENTATION" >/dev/null
grep -F 'iCloud Drive' "$PRESENTATION" >/dev/null
grep -F 'Per-category evidence is missing.' "$PRESENTATION" >/dev/null
grep -F 'performanceSessionCoordinator.replaceBackgroundServiceStatuses' "$MAIN" >/dev/null
printf 'PASS: Session Dashboard UI source contract\n'
