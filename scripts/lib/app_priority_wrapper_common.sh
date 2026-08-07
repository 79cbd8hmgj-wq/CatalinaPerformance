#!/bin/sh

validate_requesting_uid() {
    case ${1:-} in
        ''|*[!0-9]*) return 1 ;;
        0) return 1 ;;
        *) REQUESTING_UID=$1; return 0 ;;
    esac
}

require_priority_agent() {
    PRIORITY_AGENT=${CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH:-}
    [ -n "$PRIORITY_AGENT" ] || return 1
    [ -f "$PRIORITY_AGENT" ] || return 1
    [ -x "$PRIORITY_AGENT" ] || return 1
}

run_priority_agent() {
    "$PRIORITY_AGENT" "$@"
}
