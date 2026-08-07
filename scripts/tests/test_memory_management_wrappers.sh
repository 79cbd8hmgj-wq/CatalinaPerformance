#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." 2>/dev/null && pwd -P)
TMP=${TMPDIR:-/tmp}/cp-memory-wrapper-test-$$
rm -rf "$TMP"
mkdir -p "$TMP/lib" "$TMP/config/memory_management"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cp "$ROOT/scripts/performance_on_with_priority.sh" "$TMP/"
cp "$ROOT/scripts/performance_off_with_priority.sh" "$TMP/"
cp "$ROOT/scripts/emergency_restore_with_priority.sh" "$TMP/"
cp "$ROOT/scripts/lib/app_priority_wrapper_common.sh" "$TMP/lib/"
cp "$ROOT/scripts/lib/background_service_wrapper_common.sh" "$TMP/lib/"
[ -f "$ROOT/scripts/lib/memory_management_wrapper_common.sh" ] && cp "$ROOT/scripts/lib/memory_management_wrapper_common.sh" "$TMP/lib/"

cat > "$TMP/CatalinaPerformancePriorityAgent" <<'AGENT'
#!/bin/sh
printf 'priority:%s\n' "$1" >> "$FAKE_LOG"
case "$1" in
    validate) exit "${FAKE_PRIORITY_VALIDATE_EXIT:-10}" ;;
    start) exit "${FAKE_PRIORITY_START_EXIT:-0}" ;;
    stop-and-restore) exit "${FAKE_PRIORITY_RESTORE_EXIT:-11}" ;;
    *) exit 1 ;;
esac
AGENT

cat > "$TMP/CatalinaPerformanceMemoryAgent" <<'AGENT'
#!/bin/sh
printf 'memory:%s\n' "$1" >> "$FAKE_LOG"
case "$1" in
    validate) exit "${FAKE_MEMORY_VALIDATE_EXIT:-0}" ;;
    start) exit "${FAKE_MEMORY_START_EXIT:-0}" ;;
    stop-and-restore) exit "${FAKE_MEMORY_RESTORE_EXIT:-0}" ;;
    *) exit 1 ;;
esac
AGENT

cat > "$TMP/background_service_settings_apply.sh" <<'CORE'
#!/bin/sh
exit 10
CORE
cat > "$TMP/background_service_settings_restore.sh" <<'CORE'
#!/bin/sh
exit 10
CORE
cat > "$TMP/performance_on.sh" <<'CORE'
#!/bin/sh
printf 'core:on\n' >> "$FAKE_LOG"
exit "${FAKE_ON_EXIT:-0}"
CORE
cat > "$TMP/performance_off.sh" <<'CORE'
#!/bin/sh
printf 'core:off\n' >> "$FAKE_LOG"
exit "${FAKE_OFF_EXIT:-0}"
CORE
cat > "$TMP/emergency_restore.sh" <<'CORE'
#!/bin/sh
printf 'core:emergency\n' >> "$FAKE_LOG"
exit "${FAKE_EMERGENCY_EXIT:-0}"
CORE
printf '{}\n' > "$TMP/config/memory_management/desired-state.json"
chmod +x "$TMP"/*.sh "$TMP/CatalinaPerformancePriorityAgent" "$TMP/CatalinaPerformanceMemoryAgent" "$TMP/lib"/*.sh 2>/dev/null || true

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }
assert_log() {
    expected=$1
    label=$2
    actual=$(cat "$FAKE_LOG" 2>/dev/null || true)
    [ "$actual" = "$expected" ] && pass "$label" || {
        printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2
        fail "$label"
    }
}
run_wrapper() {
    : > "$FAKE_LOG"
    CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH="$TMP/CatalinaPerformancePriorityAgent" \
    CATALINA_PERFORMANCE_MEMORY_AGENT_PATH="$TMP/CatalinaPerformanceMemoryAgent" \
    CATALINA_PERFORMANCE_MEMORY_DESIRED_STATE_FILE="$TMP/config/memory_management/desired-state.json" \
    FAKE_LOG="$FAKE_LOG" \
    FAKE_PRIORITY_VALIDATE_EXIT=${FAKE_PRIORITY_VALIDATE_EXIT:-10} \
    FAKE_PRIORITY_START_EXIT=${FAKE_PRIORITY_START_EXIT:-0} \
    FAKE_PRIORITY_RESTORE_EXIT=${FAKE_PRIORITY_RESTORE_EXIT:-11} \
    FAKE_MEMORY_VALIDATE_EXIT=${FAKE_MEMORY_VALIDATE_EXIT:-0} \
    FAKE_MEMORY_START_EXIT=${FAKE_MEMORY_START_EXIT:-0} \
    FAKE_MEMORY_RESTORE_EXIT=${FAKE_MEMORY_RESTORE_EXIT:-0} \
    FAKE_ON_EXIT=${FAKE_ON_EXIT:-0} \
    FAKE_OFF_EXIT=${FAKE_OFF_EXIT:-0} \
    FAKE_EMERGENCY_EXIT=${FAKE_EMERGENCY_EXIT:-0} \
    /bin/sh "$1" ${2:-}
}
FAKE_LOG="$TMP/log"

FAKE_PRIORITY_VALIDATE_EXIT=10
FAKE_MEMORY_VALIDATE_EXIT=0
FAKE_MEMORY_START_EXIT=0
run_wrapper "$TMP/performance_on_with_priority.sh" "--requesting-uid 501 --yes"
status=$?
[ "$status" -eq 0 ] && pass "memory ON succeeds with App Priority disabled" || fail "memory ON succeeds with App Priority disabled"
assert_log 'memory:validate
priority:validate
core:on
memory:start' "ON validates memory before core and starts memory after core"

FAKE_PRIORITY_VALIDATE_EXIT=0
FAKE_PRIORITY_START_EXIT=0
FAKE_MEMORY_START_EXIT=1
run_wrapper "$TMP/performance_on_with_priority.sh" "--requesting-uid 501 --yes" >/dev/null 2>&1
status=$?
[ "$status" -ne 0 ] && pass "memory start failure returns nonzero" || fail "memory start failure returns nonzero"
assert_log 'memory:validate
priority:validate
core:on
priority:start
memory:start
memory:stop-and-restore
priority:stop-and-restore
core:off' "memory start failure restores priority and rolls core back"

FAKE_PRIORITY_RESTORE_EXIT=11
FAKE_MEMORY_RESTORE_EXIT=0
FAKE_OFF_EXIT=0
run_wrapper "$TMP/performance_off_with_priority.sh" "--requesting-uid 501"
status=$?
[ "$status" -eq 0 ] && pass "OFF restores memory when App Priority has no state" || fail "OFF restores memory when App Priority has no state"
assert_log 'memory:stop-and-restore
priority:stop-and-restore
core:off' "OFF always restores memory before core OFF"

FAKE_PRIORITY_RESTORE_EXIT=1
FAKE_MEMORY_RESTORE_EXIT=1
FAKE_OFF_EXIT=0
run_wrapper "$TMP/performance_off_with_priority.sh" "--requesting-uid 501" >/dev/null 2>&1
status=$?
[ "$status" -ne 0 ] && pass "restore failures return nonzero" || fail "restore failures return nonzero"
assert_log 'memory:stop-and-restore
priority:stop-and-restore
core:off' "OFF continues through independent restore failures"

FAKE_PRIORITY_RESTORE_EXIT=1
FAKE_MEMORY_RESTORE_EXIT=1
FAKE_EMERGENCY_EXIT=0
run_wrapper "$TMP/emergency_restore_with_priority.sh" "--requesting-uid 501 --yes" >/dev/null 2>&1
status=$?
[ "$status" -ne 0 ] && pass "Emergency reports memory/priority restore failure" || fail "Emergency reports memory/priority restore failure"
assert_log 'memory:stop-and-restore
priority:stop-and-restore
core:emergency' "Emergency attempts memory restoration even when another subsystem fails"

: > "$FAKE_LOG"
CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH="$TMP/CatalinaPerformancePriorityAgent" \
CATALINA_PERFORMANCE_MEMORY_AGENT_PATH="$TMP/not-the-memory-agent" \
CATALINA_PERFORMANCE_MEMORY_DESIRED_STATE_FILE="$TMP/config/memory_management/desired-state.json" \
FAKE_LOG="$FAKE_LOG" \
/bin/sh "$TMP/performance_on_with_priority.sh" --requesting-uid 501 --yes >/dev/null 2>&1
status=$?
[ "$status" -ne 0 ] && pass "arbitrary memory agent path is rejected" || fail "arbitrary memory agent path is rejected"
[ ! -s "$FAKE_LOG" ] && pass "rejected memory path runs no child" || fail "rejected memory path runs no child"

for file in "$ROOT/scripts/performance_on_with_priority.sh" "$ROOT/scripts/performance_off_with_priority.sh" "$ROOT/scripts/emergency_restore_with_priority.sh"; do
    ! grep -F 'nohup' "$file" >/dev/null || fail "wrapper rejects nohup: $file"
    ! grep -E 'LaunchDaemon|launchctl[[:space:]]+(bootstrap|load)' "$file" >/dev/null || fail "wrapper rejects permanent daemon install: $file"
done

if [ "$FAIL" -ne 0 ]; then
    printf '%s Memory Management wrapper assertions failed; %s passed.\n' "$FAIL" "$PASS" >&2
    exit 1
fi
printf 'All %s Memory Management wrapper assertions passed.\n' "$PASS"
