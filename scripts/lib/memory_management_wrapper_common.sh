#!/bin/sh

require_memory_agent() {
    MEMORY_AGENT=${CATALINA_PERFORMANCE_MEMORY_AGENT_PATH:-}
    [ -n "$MEMORY_AGENT" ] || {
        script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || return 1
        bundled="$script_dir/../bin/CatalinaPerformanceMemoryAgent"
        package_build="$script_dir/../app/CatalinaPerformance/.build/debug/CatalinaPerformanceMemoryAgent"
        if [ -x "$bundled" ]; then
            MEMORY_AGENT=$bundled
        elif [ -x "$package_build" ]; then
            MEMORY_AGENT=$package_build
        else
            return 1
        fi
    }
    [ "$(basename -- "$MEMORY_AGENT")" = "CatalinaPerformanceMemoryAgent" ] || return 1
    [ -f "$MEMORY_AGENT" ] || return 1
    [ -x "$MEMORY_AGENT" ] || return 1
}

require_memory_desired_state() {
    MEMORY_DESIRED_STATE=${CATALINA_PERFORMANCE_MEMORY_DESIRED_STATE_FILE:-}
    [ -z "$MEMORY_DESIRED_STATE" ] && return 0
    [ -f "$MEMORY_DESIRED_STATE" ] || return 1
    [ ! -L "$MEMORY_DESIRED_STATE" ] || return 1
    case "$MEMORY_DESIRED_STATE" in
        */Library/Application\ Support/CatalinaPerformance/memory_management/desired-state.json|*/config/memory_management/desired-state.json) ;;
        *) return 1 ;;
    esac
}

run_memory_agent() {
    if [ -n "${MEMORY_DESIRED_STATE:-}" ]; then
        CATALINA_PERFORMANCE_MEMORY_DESIRED_STATE_FILE="$MEMORY_DESIRED_STATE" "$MEMORY_AGENT" "$@"
    else
        "$MEMORY_AGENT" "$@"
    fi
}
