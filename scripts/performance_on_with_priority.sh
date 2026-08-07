#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
. "$SCRIPT_DIR/lib/app_priority_wrapper_common.sh"
. "$SCRIPT_DIR/lib/background_service_wrapper_common.sh"
. "$SCRIPT_DIR/lib/memory_management_wrapper_common.sh"

REQUESTING_UID=
ASSUME_YES=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --requesting-uid)
            [ "$#" -ge 2 ] || { printf 'Missing UID value.\n' >&2; exit 2; }
            validate_requesting_uid "$2" || { printf 'Invalid requesting UID.\n' >&2; exit 2; }
            shift 2
            ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --help|-h) printf 'Usage: %s --requesting-uid <uid> [--yes]\n' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$REQUESTING_UID" ] || { printf 'Missing --requesting-uid.\n' >&2; exit 2; }
require_memory_agent || { printf 'Memory Management agent is missing, unsafe, or not executable.\n' >&2; exit 1; }
require_priority_agent || { printf 'Priority agent is missing or not executable.\n' >&2; exit 1; }
prepare_background_service_wrapper_environment

run_memory_agent validate --uid "$REQUESTING_UID"
memory_validate_status=$?
[ "$memory_validate_status" -eq 0 ] || {
    printf 'Memory Management desired-state validation failed.\n' >&2
    exit "$memory_validate_status"
}

run_priority_agent validate --uid "$REQUESTING_UID"
validate_status=$?
priority_enabled=1
case "$validate_status" in
    0) ;;
    10) priority_enabled=0 ;;
    *) printf 'App Priority configuration validation failed.\n' >&2; exit "$validate_status" ;;
esac

apply_background_service_settings
background_status=$?
[ "$background_status" -ne 21 ] || exit 21

core_args=
[ "$ASSUME_YES" -eq 1 ] && core_args=--yes
if [ -n "$core_args" ]; then
    /bin/sh "$SCRIPT_DIR/performance_on.sh" "$core_args"
else
    /bin/sh "$SCRIPT_DIR/performance_on.sh"
fi
core_status=$?
if [ "$core_status" -ne 0 ]; then
    restore_background_service_settings >/dev/null 2>&1 || true
    exit "$core_status"
fi

if [ "$priority_enabled" -eq 1 ]; then
    run_priority_agent start --uid "$REQUESTING_UID"
    start_status=$?
    if [ "$start_status" -ne 0 ]; then
        printf 'Priority monitor failed to start; rolling Performance Mode back.\n' >&2
        /bin/sh "$SCRIPT_DIR/performance_off.sh" --force >/dev/null 2>&1 || true
        restore_background_service_settings >/dev/null 2>&1 || true
        exit "$start_status"
    fi
fi

run_memory_agent start --uid "$REQUESTING_UID"
memory_start_status=$?
if [ "$memory_start_status" -ne 0 ]; then
    printf 'Memory Management monitor failed to start; rolling Performance Mode back.\n' >&2
    run_memory_agent stop-and-restore --uid "$REQUESTING_UID" >/dev/null 2>&1 || true
    if [ "$priority_enabled" -eq 1 ]; then
        run_priority_agent stop-and-restore --uid "$REQUESTING_UID" >/dev/null 2>&1 || true
    fi
    /bin/sh "$SCRIPT_DIR/performance_off.sh" --force >/dev/null 2>&1 || true
    restore_background_service_settings >/dev/null 2>&1 || true
    exit "$memory_start_status"
fi
exit 0
