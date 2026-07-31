#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WINDOW="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/SessionDashboardWindowController.swift"
MAIN="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift"
PACKAGE="$ROOT/scripts/package_app.sh"
MODELS="$ROOT/app/CatalinaPerformance/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift"

test -f "$WINDOW"
grep -F 'final class SessionDashboardWindowController: NSWindowController, NSWindowDelegate' "$WINDOW" >/dev/null
grep -F 'setFrameAutosaveName("CatalinaPerformance.SessionDashboard")' "$WINDOW" >/dev/null
grep -F 'Refresh Now' "$WINDOW" >/dev/null
grep -F 'Last Completed Session' "$WINDOW" >/dev/null
grep -F 'Completed: ' "$WINDOW" >/dev/null
grep -F 'Restore result: ' "$WINDOW" >/dev/null
grep -F 'Unavailable' "$WINDOW" >/dev/null
grep -F 'func render(_ viewModel: SessionDashboardViewModel)' "$WINDOW" >/dev/null
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
grep -F 'finalizationCompleted(commandEvidence:' "$MAIN" >/dev/null
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
printf 'PASS: Session Dashboard UI source contract\n'
