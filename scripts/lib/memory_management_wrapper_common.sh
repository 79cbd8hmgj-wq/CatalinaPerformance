#!/bin/sh

require_memory_agent() {
    MEMORY_AGENT=${CATALINA_PERFORMANCE_MEMORY_AGENT_PATH:-}
    [ -n "$MEMORY_AGENT" ] || return 1
    [ "$(basename -- "$MEMORY_AGENT")" = "CatalinaPerformanceMemoryAgent" ] || return 1
    [ -f "$MEMORY_AGENT" ] || return 1
    [ -x "$MEMORY_AGENT" ] || return 1
}

require_memory_desired_state() {
    MEMORY_DESIRED_STATE=${CATALINA_PERFORMANCE_MEMORY_DESIRED_STATE_FILE:-}
    [ -n "$MEMORY_DESIRED_STATE" ] || return 1
    [ -f "$MEMORY_DESIRED_STATE" ] || return 1
    [ ! -L "$MEMORY_DESIRED_STATE" ] || return 1
}

run_memory_agent() {
    "$MEMORY_AGENT" "$@"
}
