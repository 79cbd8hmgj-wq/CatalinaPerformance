#!/bin/sh
set -u

usage() {
    printf 'Usage: %s --output <path>\n' "$0"
}

OUTPUT=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            [ "$#" -ge 2 ] || { printf 'Missing value for --output.\n' >&2; exit 2; }
            OUTPUT=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$OUTPUT" ] || { printf 'Missing --output.\n' >&2; usage >&2; exit 2; }
OUTPUT_DIR=$(dirname -- "$OUTPUT")
[ -d "$OUTPUT_DIR" ] || { printf 'Output directory does not exist: %s\n' "$OUTPUT_DIR" >&2; exit 2; }
[ -x /usr/bin/taskpolicy ] || { printf '/usr/bin/taskpolicy is unavailable.\n' >&2; exit 1; }

umask 077
: > "$OUTPUT" || { printf 'Unable to create output file: %s\n' "$OUTPUT" >&2; exit 1; }

section() {
    printf '\n===== %s =====\n' "$1" >> "$OUTPUT"
}

cleanup() {
    if [ -n "${CHILD_PID:-}" ]; then
        /bin/kill "$CHILD_PID" >/dev/null 2>&1 || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

section 'CatalinaPerformance taskpolicy calibration'
printf 'This calibration targets only the disposable child created by this script.\n' >> "$OUTPUT"
printf 'No arbitrary PID input, sudo, launchd installation, or persistent helper is used.\n' >> "$OUTPUT"
printf 'Captured at: ' >> "$OUTPUT"
/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' >> "$OUTPUT" 2>&1 || true
/usr/bin/sw_vers >> "$OUTPUT" 2>&1 || true

section 'taskpolicy help'
/usr/bin/taskpolicy -h >> "$OUTPUT" 2>&1
HELP_STATUS=$?
printf '[taskpolicy -h exit %s]\n' "$HELP_STATUS" >> "$OUTPUT"

section 'Disposable process'
/bin/sleep 30 &
CHILD_PID=$!
printf 'child pid: %s\n' "$CHILD_PID" >> "$OUTPUT"
/bin/ps -ww -p "$CHILD_PID" -o pid= -o uid= -o nice= -o command= >> "$OUTPUT" 2>&1 || true

section 'Read/query attempt before mutation'
QUERY_BEFORE=$(/usr/bin/taskpolicy -p "$CHILD_PID" 2>&1)
QUERY_BEFORE_STATUS=$?
printf '%s\n' "$QUERY_BEFORE" >> "$OUTPUT"
printf '[taskpolicy -p child exit %s]\n' "$QUERY_BEFORE_STATUS" >> "$OUTPUT"

section 'Disposable background round trip'
/usr/bin/taskpolicy -b -p "$CHILD_PID" >> "$OUTPUT" 2>&1
APPLY_STATUS=$?
printf '[taskpolicy -b -p child exit %s]\n' "$APPLY_STATUS" >> "$OUTPUT"
/bin/ps -ww -p "$CHILD_PID" -o pid= -o uid= -o nice= -o command= >> "$OUTPUT" 2>&1 || true

section 'Read/query attempt after background apply'
QUERY_AFTER=$(/usr/bin/taskpolicy -p "$CHILD_PID" 2>&1)
QUERY_AFTER_STATUS=$?
printf '%s\n' "$QUERY_AFTER" >> "$OUTPUT"
printf '[taskpolicy -p child exit %s]\n' "$QUERY_AFTER_STATUS" >> "$OUTPUT"

section 'Disposable background removal'
/usr/bin/taskpolicy -B -p "$CHILD_PID" >> "$OUTPUT" 2>&1
RESTORE_STATUS=$?
printf '[taskpolicy -B -p child exit %s]\n' "$RESTORE_STATUS" >> "$OUTPUT"
/bin/ps -ww -p "$CHILD_PID" -o pid= -o uid= -o nice= -o command= >> "$OUTPUT" 2>&1 || true

section 'Read/query attempt after removal'
QUERY_RESTORED=$(/usr/bin/taskpolicy -p "$CHILD_PID" 2>&1)
QUERY_RESTORED_STATUS=$?
printf '%s\n' "$QUERY_RESTORED" >> "$OUTPUT"
printf '[taskpolicy -p child exit %s]\n' "$QUERY_RESTORED_STATUS" >> "$OUTPUT"

section 'Calibration decision inputs'
printf 'query_before_exit=%s\n' "$QUERY_BEFORE_STATUS" >> "$OUTPUT"
printf 'apply_background_exit=%s\n' "$APPLY_STATUS" >> "$OUTPUT"
printf 'query_after_exit=%s\n' "$QUERY_AFTER_STATUS" >> "$OUTPUT"
printf 'remove_background_exit=%s\n' "$RESTORE_STATUS" >> "$OUTPUT"
printf 'query_restored_exit=%s\n' "$QUERY_RESTORED_STATUS" >> "$OUTPUT"
printf 'Exact production support requires a readable original policy state plus verifiable exact restoration. Exit success for -b/-B alone is not sufficient.\n' >> "$OUTPUT"
printf 'I/O policy remains disabled until this evidence is reviewed.\n' >> "$OUTPUT"

printf 'Wrote taskpolicy calibration evidence to %s\n' "$OUTPUT"
exit 0
