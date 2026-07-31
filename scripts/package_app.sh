#!/bin/sh
# Package the CatalinaPerformance local GUI as a development-only .app bundle.

set -u

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P) || exit 1
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P) || exit 1
PACKAGE_DIR="$REPO_ROOT/app/CatalinaPerformance"
APP_BUILD_DIR="$REPO_ROOT/build"
APP_NAME="CatalinaPerformance"
PRIORITY_AGENT_NAME="CatalinaPerformancePriorityAgent"
APP_BUNDLE="$APP_BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BUNDLE_EXECUTABLE="$MACOS_DIR/$APP_NAME"
GUI_EXECUTABLE="$MACOS_DIR/${APP_NAME}-gui"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
# Runtime bundle locations: Contents/Resources/bin and Contents/Resources/scripts.
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_DIR="$RESOURCES_DIR/bin"
BUNDLED_SCRIPTS_DIR="$RESOURCES_DIR/scripts"
BUNDLED_LIB_DIR="$BUNDLED_SCRIPTS_DIR/lib"

error() {
    printf 'Error: %s\n' "$1" >&2
}

require_file() {
    if [ ! -f "$1" ]; then
        error "Required file was not found: $1"
        exit 1
    fi
}

require_runtime_script() {
    if [ ! -f "$1" ]; then
        error "Required script was not found: $1"
        exit 1
    fi
}

if ! command -v xcode-select >/dev/null 2>&1; then
    error "xcode-select was not found. Install Xcode 12.4 for macOS Catalina."
    exit 1
fi

XCODE_PATH=$(xcode-select -p 2>/dev/null) || {
    error "No Xcode developer directory is selected. Install Xcode 12.4, then run 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'."
    exit 1
}

if [ ! -d "$XCODE_PATH" ]; then
    error "The selected developer directory does not exist: $XCODE_PATH"
    exit 1
fi

case "$XCODE_PATH" in
    */Contents/Developer) ;;
    *)
        error "The selected developer directory does not look like full Xcode: $XCODE_PATH"
        error "On Catalina, select full Xcode 12.4 with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        exit 1
        ;;
esac

if ! command -v xcrun >/dev/null 2>&1; then
    error "xcrun was not found. The selected Xcode developer tools appear incomplete: $XCODE_PATH"
    exit 1
fi

if ! xcrun -f xctest >/dev/null 2>&1; then
    error "xcrun cannot find xctest. The selected Xcode install may be incomplete or command line tools may be selected instead of full Xcode."
    error "Selected developer directory: $XCODE_PATH"
    error "On Catalina, install/open Xcode 12.4 and select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    error "swift was not found in PATH. Install Xcode 12.4 or ensure Xcode's toolchain is selected."
    exit 1
fi

if [ ! -d "$PACKAGE_DIR" ]; then
    error "Swift package directory was not found: $PACKAGE_DIR"
    exit 1
fi

require_file "$PACKAGE_DIR/Package.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformance/main.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformance/ForegroundSessionPanelController.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformance/AppPriorityPanelController.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformanceCore/ForegroundSession.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformanceCore/ScriptSequenceCoordinator.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformancePriorityAgent/main.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformancePriorityCore/AppPriorityAgentService.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformance/SessionDashboardWindowController.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformanceDashboardCore/SessionMetricModels.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformanceDashboardCore/SessionMetricsCollector.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionCoordinator.swift"
require_file "$PACKAGE_DIR/Sources/CatalinaPerformanceDashboardCore/PerformanceSessionStore.swift"

RUNTIME_SCRIPTS="
status_report.sh
performance_on.sh
performance_off.sh
emergency_restore.sh
performance_on_with_priority.sh
performance_off_with_priority.sh
emergency_restore_with_priority.sh
memory_storage_report.sh
app_priority_report.sh
thermal_fan_report.sh
foreground_session_list.sh
foreground_session_apply.sh
foreground_session_restore.sh
foreground_session_state.sh
ui_responsiveness_apply.sh
ui_responsiveness_restore.sh
"
for runtime_script in $RUNTIME_SCRIPTS; do
    require_runtime_script "$SCRIPT_DIR/$runtime_script"
done
require_runtime_script "$SCRIPT_DIR/lib/foreground_session_common.sh"
require_runtime_script "$SCRIPT_DIR/lib/app_priority_wrapper_common.sh"

printf 'Using developer directory: %s\n' "$XCODE_PATH"
printf 'Building CatalinaPerformance GUI package: %s\n' "$PACKAGE_DIR"
cd "$PACKAGE_DIR" || exit 1
swift build --product CatalinaPerformance || exit 1
swift build --product "$PRIORITY_AGENT_NAME" || exit 1

BUILT_EXECUTABLE="$PACKAGE_DIR/.build/debug/$APP_NAME"
BUILT_PRIORITY_AGENT="$PACKAGE_DIR/.build/debug/$PRIORITY_AGENT_NAME"
if [ ! -x "$BUILT_EXECUTABLE" ]; then
    error "Built executable was not found or is not executable: $BUILT_EXECUTABLE"
    exit 1
fi
if [ ! -x "$BUILT_PRIORITY_AGENT" ]; then
    error "Built priority agent was not found or is not executable: $BUILT_PRIORITY_AGENT"
    exit 1
fi

printf 'Creating local app bundle: %s\n' "$APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$BIN_DIR" "$BUNDLED_LIB_DIR" || exit 1
install -m 755 "$BUILT_EXECUTABLE" "$GUI_EXECUTABLE" || exit 1
install -m 755 "$BUILT_PRIORITY_AGENT" "$BIN_DIR/$PRIORITY_AGENT_NAME" || exit 1

for runtime_script in $RUNTIME_SCRIPTS; do
    install -m 755 "$SCRIPT_DIR/$runtime_script" "$BUNDLED_SCRIPTS_DIR/$runtime_script" || exit 1
done
install -m 755 "$SCRIPT_DIR/lib/foreground_session_common.sh" "$BUNDLED_LIB_DIR/foreground_session_common.sh" || exit 1
install -m 755 "$SCRIPT_DIR/lib/app_priority_wrapper_common.sh" "$BUNDLED_LIB_DIR/app_priority_wrapper_common.sh" || exit 1

cat > "$INFO_PLIST" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CatalinaPerformance</string>
    <key>CFBundleIdentifier</key>
    <string>local.CatalinaPerformance</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CatalinaPerformance</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST_EOF

cat > "$BUNDLE_EXECUTABLE" <<'EOF_LAUNCHER'
#!/bin/sh
# Local development launcher generated by scripts/package_app.sh.
RESOURCE_DIR=$(CDPATH= cd "$(dirname "$0")/../Resources" 2>/dev/null && pwd -P) || exit 1

if [ -z "${CATALINA_PERFORMANCE_SCRIPTS_DIR:-}" ]; then
    export CATALINA_PERFORMANCE_SCRIPTS_DIR="$RESOURCE_DIR/scripts"
fi
if [ -z "${CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH:-}" ]; then
    export CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH="$RESOURCE_DIR/bin/CatalinaPerformancePriorityAgent"
fi

exec "$(dirname "$0")/CatalinaPerformance-gui" "$@"
EOF_LAUNCHER
chmod 755 "$BUNDLE_EXECUTABLE" || exit 1

for required_runtime in \
    "$BIN_DIR/$PRIORITY_AGENT_NAME" \
    "$BUNDLED_SCRIPTS_DIR/performance_on_with_priority.sh" \
    "$BUNDLED_SCRIPTS_DIR/performance_off_with_priority.sh" \
    "$BUNDLED_SCRIPTS_DIR/emergency_restore_with_priority.sh"
do
    if [ ! -x "$required_runtime" ]; then
        error "Packaged priority resource is missing or not executable: $required_runtime"
        exit 1
    fi
done

printf 'Packaged priority agent: %s\n' "$BIN_DIR/$PRIORITY_AGENT_NAME"
printf 'Packaged Performance ON wrapper: %s\n' "$BUNDLED_SCRIPTS_DIR/performance_on_with_priority.sh"
printf 'Packaged Performance OFF wrapper: %s\n' "$BUNDLED_SCRIPTS_DIR/performance_off_with_priority.sh"
printf 'Packaged Emergency Restore wrapper: %s\n' "$BUNDLED_SCRIPTS_DIR/emergency_restore_with_priority.sh"
printf 'Created %s\n' "$APP_BUNDLE"
printf 'Launch with: open %s\n' "$APP_BUNDLE"
printf 'This bundle is unsigned, not notarized, and intended only for local development. Runtime scripts and the session-scoped priority agent are bundled inside the app.\n'
