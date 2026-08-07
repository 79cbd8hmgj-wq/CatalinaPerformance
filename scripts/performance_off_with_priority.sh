#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
. "$SCRIPT_DIR/lib/app_priority_wrapper_common.sh"
. "$SCRIPT_DIR/lib/background_service_wrapper_common.sh"
. "$SCRIPT_DIR/lib/memory_management_wrapper_common.sh"

REQUESTING_UID=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --requesting-uid)
            [ "$#" -ge 2 ] || { printf 'Missing UID value.\n' >&2; exit 2; }
            validate_requesting_uid "$2" || { printf 'Invalid requesting UID.\n' >&2; exit 2; }
            shift 2
            ;;
        --help|-h) printf 'Usage: %s --requesting-uid <uid>\n' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[ -n "$REQUESTING_UID" ] || { printf 'Missing --requesting-uid.\n' >&2; exit 2; }
prepare_background_service_wrapper_environment

memory_failed=0
if require_memory_agent; then
    run_memory_agent stop-and-restore --uid "$REQUESTING_UID"
    memory_status=$?
    case "$memory_status" in 0|10) ;; *) memory_failed=1 ;; esac
else
    memory_failed=1
fi

priority_failed=0
if require_priority_agent; then
    run_priority_agent stop-and-restore --uid "$REQUESTING_UID"
    priority_status=$?
    case "$priority_status" in 0|11) ;; *) priority_failed=1 ;; esac
else
    priority_failed=1
fi

background_failed=0
restore_background_service_settings || background_failed=1
/bin/sh "$SCRIPT_DIR/performance_off.sh"
core_status=$?
if [ "$memory_failed" -ne 0 ] || [ "$priority_failed" -ne 0 ] || [ "$background_failed" -ne 0 ] || [ "$core_status" -ne 0 ]; then
    exit 1
fi
exit 0
