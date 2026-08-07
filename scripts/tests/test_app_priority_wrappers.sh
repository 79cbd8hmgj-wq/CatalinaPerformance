#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." 2>/dev/null && pwd -P)
TMP=${TMPDIR:-/tmp}/cp-priority-wrapper-test-$$
rm -rf "$TMP"
mkdir -p "$TMP/lib"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
cp "$ROOT/scripts/performance_on_with_priority.sh" "$TMP/"
cp "$ROOT/scripts/performance_off_with_priority.sh" "$TMP/"
cp "$ROOT/scripts/emergency_restore_with_priority.sh" "$TMP/"
cp "$ROOT/scripts/lib/app_priority_wrapper_common.sh" "$TMP/lib/"
cp "$ROOT/scripts/lib/memory_management_wrapper_common.sh" "$TMP/lib/"
cp "$ROOT/scripts/lib/background_service_wrapper_common.sh" "$TMP/lib/"

cat > "$TMP/fake-agent" <<'AGENT'
#!/bin/sh
printf 'agent:%s\n' "$1" >> "$FAKE_LOG"
case "$1" in
    validate) exit "${FAKE_VALIDATE_EXIT:-0}" ;;
    start) exit "${FAKE_START_EXIT:-0}" ;;
    stop-and-restore) exit "${FAKE_RESTORE_EXIT:-0}" ;;
    *) exit 1 ;;
esac
AGENT
cat > "$TMP/CatalinaPerformanceMemoryAgent" <<'AGENT'
#!/bin/sh
case "$1" in
    validate|start|stop-and-restore) exit 0 ;;
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
chmod +x "$TMP"/*.sh "$TMP/fake-agent" "$TMP/CatalinaPerformanceMemoryAgent" "$TMP/lib"/*.sh

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }
assert_log() {
    expected=$1
    label=$2
    actual=$(cat "$FAKE_LOG" 2>/dev/null || true)
    [ "$actual" = "$expected" ] && pass "$label" || { printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2; fail "$label"; }
}
run_wrapper() {
    : > "$FAKE_LOG"
    CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH="$TMP/fake-agent" \
    CATALINA_PERFORMANCE_MEMORY_AGENT_PATH="$TMP/CatalinaPerformanceMemoryAgent" \
    FAKE_LOG="$FAKE_LOG" FAKE_VALIDATE_EXIT=${FAKE_VALIDATE_EXIT:-0} \
    FAKE_START_EXIT=${FAKE_START_EXIT:-0} FAKE_RESTORE_EXIT=${FAKE_RESTORE_EXIT:-0} \
    FAKE_ON_EXIT=${FAKE_ON_EXIT:-0} FAKE_OFF_EXIT=${FAKE_OFF_EXIT:-0} \
    FAKE_EMERGENCY_EXIT=${FAKE_EMERGENCY_EXIT:-0} \
    /bin/sh "$1" ${2:-}
}
FAKE_LOG="$TMP/log"

FAKE_VALIDATE_EXIT=10; FAKE_START_EXIT=0; run_wrapper "$TMP/performance_on_with_priority.sh" "--requesting-uid 501 --yes"; status=$?
[ "$status" -eq 0 ] && pass "disabled validation exits zero" || fail "disabled validation exits zero"
assert_log 'agent:validate
core:on' "disabled validation runs core ON only"

FAKE_VALIDATE_EXIT=0; FAKE_START_EXIT=0; run_wrapper "$TMP/performance_on_with_priority.sh" "--requesting-uid 501 --yes"; status=$?
[ "$status" -eq 0 ] && pass "valid selection exits zero" || fail "valid selection exits zero"
assert_log 'agent:validate
core:on
agent:start' "valid selection starts after core ON"

FAKE_VALIDATE_EXIT=1; run_wrapper "$TMP/performance_on_with_priority.sh" "--requesting-uid 501 --yes" >/dev/null 2>&1; status=$?
[ "$status" -ne 0 ] && pass "invalid selection fails" || fail "invalid selection fails"
assert_log 'agent:validate' "invalid selection prevents core ON"

FAKE_VALIDATE_EXIT=0; FAKE_START_EXIT=1; FAKE_OFF_EXIT=0; run_wrapper "$TMP/performance_on_with_priority.sh" "--requesting-uid 501 --yes" >/dev/null 2>&1; status=$?
[ "$status" -ne 0 ] && pass "start failure returns nonzero" || fail "start failure returns nonzero"
assert_log 'agent:validate
core:on
agent:start
core:off' "start failure rolls core ON back"

FAKE_RESTORE_EXIT=1; FAKE_OFF_EXIT=0; run_wrapper "$TMP/performance_off_with_priority.sh" "--requesting-uid 501" >/dev/null 2>&1; status=$?
[ "$status" -ne 0 ] && pass "priority restore failure returns nonzero" || fail "priority restore failure returns nonzero"
assert_log 'agent:stop-and-restore
core:off' "priority restore failure still runs core OFF"

FAKE_RESTORE_EXIT=11; FAKE_OFF_EXIT=0; run_wrapper "$TMP/performance_off_with_priority.sh" "--requesting-uid 501"; status=$?
[ "$status" -eq 0 ] && pass "no state defers to core OFF" || fail "no state defers to core OFF"
assert_log 'agent:stop-and-restore
core:off' "no state still runs core OFF"

FAKE_RESTORE_EXIT=1; FAKE_EMERGENCY_EXIT=0; run_wrapper "$TMP/emergency_restore_with_priority.sh" "--requesting-uid 501 --yes" >/dev/null 2>&1; status=$?
[ "$status" -ne 0 ] && pass "emergency priority failure returns nonzero" || fail "emergency priority failure returns nonzero"
assert_log 'agent:stop-and-restore
core:emergency' "emergency priority failure still runs core emergency"

: > "$FAKE_LOG"
CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH="$TMP/fake-agent" \
CATALINA_PERFORMANCE_MEMORY_AGENT_PATH="$TMP/CatalinaPerformanceMemoryAgent" \
FAKE_LOG="$FAKE_LOG" /bin/sh "$TMP/performance_on_with_priority.sh" --requesting-uid '501;bad' >/dev/null 2>&1; status=$?
[ "$status" -eq 2 ] && pass "malformed UID exits 2" || fail "malformed UID exits 2"
[ ! -s "$FAKE_LOG" ] && pass "malformed UID runs no child" || fail "malformed UID runs no child"

if [ "$FAIL" -ne 0 ]; then
    printf '%s wrapper assertions failed; %s passed.\n' "$FAIL" "$PASS" >&2
    exit 1
fi
printf 'All %s App Priority wrapper assertions passed.\n' "$PASS"
