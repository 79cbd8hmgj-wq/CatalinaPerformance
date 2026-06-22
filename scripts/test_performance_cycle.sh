#!/bin/sh
# Run a controlled CatalinaPerformance validation cycle.
#
# Default mode is intentionally safe: it performs syntax checks, verifies that
# required scripts exist, and runs only read-only or dry-run commands. Live mode
# requires --live plus either --yes or an interactive confirmation, and refuses
# to run unless the host appears to be macOS.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)
STATE_DIR="$REPO_ROOT/.catalina_performance_state"
TEST_RUNS_DIR="$STATE_DIR/test_runs"
MARKER_FILE="$STATE_DIR/performance_mode_on"
ACTIONS_FILE="$STATE_DIR/actions_taken.txt"
RESTORE_ACTIONS_FILE="$STATE_DIR/restore_actions_taken.txt"

STATUS_SCRIPT="$SCRIPT_DIR/status_report.sh"
ON_SCRIPT="$SCRIPT_DIR/performance_on.sh"
OFF_SCRIPT="$SCRIPT_DIR/performance_off.sh"
EMERGENCY_SCRIPT="$SCRIPT_DIR/emergency_restore.sh"

LIVE=0
ASSUME_YES=0
AUTO_EMERGENCY=0
FAILURES=0
WARNINGS=0
RUN_DIR=""
SUMMARY_FILE=""

usage() {
    cat <<USAGE
Usage: $0 [--live] [--yes] [--auto-emergency]

Runs a CatalinaPerformance local validation cycle.

Default behavior is safe and non-destructive: required scripts are checked with
sh -n, status_report.sh is run read-only, and restore scripts are run only in
dry-run mode.

Options:
  --live            Run performance_on.sh and a real performance_off.sh cycle.
  --yes, -y         Skip live-mode interactive confirmation.
  --auto-emergency  If live performance_off.sh fails, run emergency_restore.sh --yes.
  --help, -h        Show this help.
USAGE
}

# Parse command-line options before any test actions are run.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --live) LIVE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --auto-emergency) AUTO_EMERGENCY=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Small helpers keep the main cycle readable and make pass/fail accounting clear.
is_macos() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ]
}

log() {
    message=$1
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf 'unknown-time')
    printf '%s %s\n' "$timestamp" "$message" | tee -a "$SUMMARY_FILE"
}

pass() {
    log "PASS: $1"
}

fail() {
    FAILURES=$((FAILURES + 1))
    log "FAIL: $1"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    log "WARN: $1"
}

# Create an isolated test-run directory under the project state directory.
prepare_run_dir() {
    mkdir -p "$TEST_RUNS_DIR"
    chmod 700 "$STATE_DIR" "$TEST_RUNS_DIR" 2>/dev/null || true
    run_id=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || printf 'unknown_time')
    RUN_DIR="$TEST_RUNS_DIR/$run_id"
    suffix=1
    while [ -e "$RUN_DIR" ]; do
        RUN_DIR="$TEST_RUNS_DIR/${run_id}_$suffix"
        suffix=$((suffix + 1))
    done
    mkdir -p "$RUN_DIR"
    SUMMARY_FILE="$RUN_DIR/summary.log"
    : > "$SUMMARY_FILE"
}

# Live mode has two explicit safety gates: macOS detection and user intent.
confirm_live_intent() {
    if [ "$LIVE" -ne 1 ]; then
        return 0
    fi

    if ! is_macos; then
        fail "Live mode refused: this host does not appear to be macOS."
        print_summary
        exit 1
    fi

    if [ "$ASSUME_YES" -eq 1 ]; then
        log "Live mode confirmation skipped because --yes was provided."
        return 0
    fi

    cat <<WARNING
CatalinaPerformance live test cycle will run performance_on.sh --yes and then
performance_off.sh for real. This may use sudo through those scripts for
reversible macOS power, Time Machine, and Spotlight changes.

The cycle will not modify SIP, delete caches, add fan control, undervolt, load
kexts, or run MSR/experimental CPU code.
WARNING
    printf 'Continue with live test cycle? Type "LIVE" to proceed: '
    read answer
    if [ "$answer" != "LIVE" ]; then
        fail "Live mode aborted by user."
        print_summary
        exit 1
    fi
}

# Verify that every expected script exists before attempting syntax or runtime checks.
check_required_scripts() {
    for script in "$STATUS_SCRIPT" "$ON_SCRIPT" "$OFF_SCRIPT" "$EMERGENCY_SCRIPT"; do
        if [ -f "$script" ]; then
            pass "Found required script: $script"
        else
            fail "Missing required script: $script"
        fi
    done
}

# Run POSIX shell syntax checks first so obvious script errors are caught early.
syntax_checks() {
    for script in "$STATUS_SCRIPT" "$ON_SCRIPT" "$OFF_SCRIPT" "$EMERGENCY_SCRIPT"; do
        if [ -f "$script" ]; then
            if sh -n "$script" > "$RUN_DIR/$(basename "$script").syntax.log" 2>&1; then
                pass "Syntax check passed: sh -n $script"
            else
                fail "Syntax check failed: sh -n $script (see $RUN_DIR/$(basename "$script").syntax.log)"
            fi
        fi
    done
}

# Run a command, capture all output, and record whether it exited successfully.
run_capture() {
    label=$1
    output_file=$2
    shift 2

    log "RUN: $label"
    if "$@" > "$output_file" 2>&1; then
        pass "$label"
        return 0
    fi

    rc=$?
    fail "$label exited with status $rc (see $output_file)"
    return "$rc"
}

# Detect expected marker and action-log signals after Performance Mode is turned on.
check_on_signals() {
    if [ -e "$MARKER_FILE" ]; then
        pass "Performance Mode ON marker exists after ON: $MARKER_FILE"
    else
        fail "Performance Mode ON marker was not created after ON."
    fi

    if [ -f "$ACTIONS_FILE" ] && grep 'Time Machine' "$ACTIONS_FILE" >/dev/null 2>&1; then
        pass "Time Machine action was attempted or explicitly skipped."
    else
        fail "No Time Machine action signal found in $ACTIONS_FILE."
    fi

    if [ -f "$ACTIONS_FILE" ] && grep 'Spotlight' "$ACTIONS_FILE" >/dev/null 2>&1; then
        pass "Spotlight action was attempted or explicitly skipped."
    else
        fail "No Spotlight action signal found in $ACTIONS_FILE."
    fi
}

# Detect expected restore signals after Performance Mode is turned off.
check_off_signals() {
    if [ ! -e "$MARKER_FILE" ]; then
        pass "Performance Mode ON marker removed after OFF."
    else
        fail "Performance Mode ON marker still exists after OFF: $MARKER_FILE"
    fi

    if [ -f "$RUN_DIR/performance_off_live.log" ] && grep 'Restore failures: 0' "$RUN_DIR/performance_off_live.log" >/dev/null 2>&1; then
        pass "performance_off.sh reported restore failures are zero."
    elif [ -f "$RESTORE_ACTIONS_FILE" ] && ! grep '^FAILED:' "$RESTORE_ACTIONS_FILE" >/dev/null 2>&1; then
        pass "No failed restore actions were recorded."
    else
        fail "Could not confirm restore failures are zero."
    fi
}

# Safe default cycle: read-only status plus restore dry-runs only.
run_default_cycle() {
    run_capture "status_report.sh read-only report" "$RUN_DIR/status_default.log" sh "$STATUS_SCRIPT" || true
    run_capture "performance_off.sh --dry-run --force" "$RUN_DIR/performance_off_dry_run_force.log" sh "$OFF_SCRIPT" --dry-run --force || true
    run_capture "emergency_restore.sh --dry-run --yes" "$RUN_DIR/emergency_restore_dry_run.log" sh "$EMERGENCY_SCRIPT" --dry-run --yes || true
    warn "Default mode did not run performance_on.sh or real performance_off.sh; use --live --yes for a real cycle on macOS."
}

# Live cycle follows the required before/during/after sequence exactly.
run_live_cycle() {
    run_capture "status_report.sh before report" "$RUN_DIR/status_before.log" sh "$STATUS_SCRIPT" || true
    run_capture "performance_off.sh --dry-run --force" "$RUN_DIR/performance_off_preflight_dry_run_force.log" sh "$OFF_SCRIPT" --dry-run --force || true
    run_capture "emergency_restore.sh --dry-run --yes" "$RUN_DIR/emergency_restore_preflight_dry_run.log" sh "$EMERGENCY_SCRIPT" --dry-run --yes || true

    run_capture "performance_on.sh --yes" "$RUN_DIR/performance_on_live.log" sh "$ON_SCRIPT" --yes || true
    check_on_signals

    run_capture "status_report.sh ON report" "$RUN_DIR/status_on.log" sh "$STATUS_SCRIPT" || true
    run_capture "performance_off.sh --dry-run" "$RUN_DIR/performance_off_dry_run.log" sh "$OFF_SCRIPT" --dry-run || true

    if run_capture "performance_off.sh live restore" "$RUN_DIR/performance_off_live.log" sh "$OFF_SCRIPT"; then
        check_off_signals
    else
        log "Emergency restore command for manual recovery: sh $EMERGENCY_SCRIPT --yes"
        if [ "$AUTO_EMERGENCY" -eq 1 ]; then
            run_capture "emergency_restore.sh --yes after OFF failure" "$RUN_DIR/emergency_restore_auto.log" sh "$EMERGENCY_SCRIPT" --yes || true
        else
            warn "Live OFF failed; emergency_restore.sh was not run automatically because --auto-emergency was not provided."
        fi
    fi

    run_capture "status_report.sh after report" "$RUN_DIR/status_after.log" sh "$STATUS_SCRIPT" || true
}

# Print a concise final summary with the log directory and aggregate result.
print_summary() {
    printf '\nCatalinaPerformance test cycle summary\n' | tee -a "$SUMMARY_FILE"
    printf 'Mode: %s\n' "$(if [ "$LIVE" -eq 1 ]; then printf live; else printf dry-run; fi)" | tee -a "$SUMMARY_FILE"
    printf 'Run directory: %s\n' "$RUN_DIR" | tee -a "$SUMMARY_FILE"
    printf 'Failures: %s\n' "$FAILURES" | tee -a "$SUMMARY_FILE"
    printf 'Warnings: %s\n' "$WARNINGS" | tee -a "$SUMMARY_FILE"
    if [ "$FAILURES" -eq 0 ]; then
        printf 'Result: PASS\n' | tee -a "$SUMMARY_FILE"
    else
        printf 'Result: FAIL\n' | tee -a "$SUMMARY_FILE"
    fi
}

prepare_run_dir
log "Starting CatalinaPerformance test cycle. Logs: $RUN_DIR"
check_required_scripts
syntax_checks

if [ "$FAILURES" -ne 0 ]; then
    print_summary
    exit 1
fi

confirm_live_intent
if [ "$LIVE" -eq 1 ]; then
    run_live_cycle
else
    run_default_cycle
fi

print_summary
if [ "$FAILURES" -ne 0 ]; then
    exit 1
fi
exit 0
