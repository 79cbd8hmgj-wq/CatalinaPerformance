#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROBE="$ROOT/scripts/visual_performance_probe.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[ -f "$PROBE" ] || fail "visual performance probe script is missing"
/bin/sh -n "$PROBE" || fail "visual performance probe has invalid shell syntax"

for required in \
    'VISUAL_PERFORMANCE_PROBE_SCHEMA=1' \
    'SYSTEM' \
    'DOCK_AUTO_HIDE' \
    'FINDER_ANIMATIONS' \
    'DOCK_LAUNCH_ANIMATION' \
    'MISSION_CONTROL_TRANSITIONS' \
    'WINDOW_OPENING_ANIMATIONS' \
    'REDUCE_MOTION' \
    'REDUCE_TRANSPARENCY' \
    'MINIMIZE_EFFECT' \
    'DOCK_AUTO_HIDE_DELAY' \
    'DOCK_AUTO_HIDE_ANIMATION' \
    'candidate_id=' \
    'candidate_domain=' \
    'candidate_key=' \
    'read_status=' \
    'read_type=' \
    'read_value='; do
    grep -F "$required" "$PROBE" >/dev/null || fail "missing required probe token: $required"
done

# Strip comments before scanning operational code so safety documentation can name exclusions.
body=$(mktemp "${TMPDIR:-/tmp}/visual-probe-body.XXXXXX") || exit 1
trap 'rm -f "$body"' EXIT HUP INT TERM
sed '/^[[:space:]]*#/d' "$PROBE" > "$body"

for forbidden in \
    'defaults write' \
    'defaults delete' \
    'killall' \
    'launchctl' \
    'sudo ' \
    'SIGKILL'; do
    if grep -F "$forbidden" "$body" >/dev/null; then
        fail "probe contains forbidden mutation token: $forbidden"
    fi
done

if grep -E '(^|[^[:alnum:]_])kill([^[:alnum:]_]|$)' "$body" >/dev/null; then
    fail "probe contains a kill operation"
fi

printf 'PASS: Visual Performance probe source contract\n'
