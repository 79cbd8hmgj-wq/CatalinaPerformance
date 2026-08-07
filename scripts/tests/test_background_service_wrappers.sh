#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cp-bg-wrapper.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/lib" "$TMP/config/memory_management"
cp "$ROOT/scripts/performance_on_with_priority.sh" "$TMP/"
cp "$ROOT/scripts/performance_off_with_priority.sh" "$TMP/"
cp "$ROOT/scripts/emergency_restore_with_priority.sh" "$TMP/"
cp "$ROOT/scripts/lib/app_priority_wrapper_common.sh" "$TMP/lib/"
cp "$ROOT/scripts/lib/background_service_wrapper_common.sh" "$TMP/lib/"
cp "$ROOT/scripts/lib/memory_management_wrapper_common.sh" "$TMP/lib/"

cat > "$TMP/fake-agent" <<'SH2'
#!/bin/sh
printf 'priority:%s\n' "$1" >> "$WRAPPER_LOG"
case "$1" in validate) exit "${VALIDATE_STATUS:-10}" ;; start) exit "${START_STATUS:-0}" ;; stop-and-restore) exit "${RESTORE_STATUS:-11}" ;; esac
exit 1
SH2
cat > "$TMP/CatalinaPerformanceMemoryAgent" <<'SH2'
#!/bin/sh
printf 'memory:%s\n' "$1" >> "$WRAPPER_LOG"
case "$1" in validate) exit "${MEMORY_VALIDATE_STATUS:-0}" ;; start) exit "${MEMORY_START_STATUS:-0}" ;; stop-and-restore) exit "${MEMORY_RESTORE_STATUS:-11}" ;; esac
exit 1
SH2
cat > "$TMP/background_service_settings_apply.sh" <<'SH2'
#!/bin/sh
printf 'background:apply\n' >> "$WRAPPER_LOG"
exit "${BACKGROUND_APPLY_STATUS:-0}"
SH2
cat > "$TMP/background_service_settings_restore.sh" <<'SH2'
#!/bin/sh
printf 'background:restore\n' >> "$WRAPPER_LOG"
exit "${BACKGROUND_RESTORE_STATUS:-0}"
SH2
cat > "$TMP/performance_on.sh" <<'SH2'
#!/bin/sh
printf 'core:on\n' >> "$WRAPPER_LOG"
exit "${CORE_ON_STATUS:-0}"
SH2
cat > "$TMP/performance_off.sh" <<'SH2'
#!/bin/sh
printf 'core:off\n' >> "$WRAPPER_LOG"
exit "${CORE_OFF_STATUS:-0}"
SH2
cat > "$TMP/emergency_restore.sh" <<'SH2'
#!/bin/sh
printf 'core:emergency\n' >> "$WRAPPER_LOG"
exit "${CORE_EMERGENCY_STATUS:-0}"
SH2
printf '{}\n' > "$TMP/config/memory_management/desired-state.json"
chmod +x "$TMP"/*.sh "$TMP/fake-agent" "$TMP/CatalinaPerformanceMemoryAgent" "$TMP/lib"/*.sh

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_log() { expected=$1; actual=$(cat "$WRAPPER_LOG"); [ "$actual" = "$expected" ] || { printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2; fail "$2"; }; }
run() {
    : > "$WRAPPER_LOG"
    export CATALINA_PERFORMANCE_PRIORITY_AGENT_PATH="$TMP/fake-agent"
    export CATALINA_PERFORMANCE_MEMORY_AGENT_PATH="$TMP/CatalinaPerformanceMemoryAgent"
    export CATALINA_PERFORMANCE_MEMORY_DESIRED_STATE_FILE="$TMP/config/memory_management/desired-state.json"
    export CATALINA_PERFORMANCE_STATE_DIR="$TMP/state"
    export WRAPPER_LOG
    export VALIDATE_STATUS="${VALIDATE_STATUS:-10}"
    export START_STATUS="${START_STATUS:-0}"
    export RESTORE_STATUS="${RESTORE_STATUS:-11}"
    export MEMORY_VALIDATE_STATUS="${MEMORY_VALIDATE_STATUS:-0}"
    export MEMORY_START_STATUS="${MEMORY_START_STATUS:-0}"
    export MEMORY_RESTORE_STATUS="${MEMORY_RESTORE_STATUS:-11}"
    export BACKGROUND_APPLY_STATUS="${BACKGROUND_APPLY_STATUS:-0}"
    export BACKGROUND_RESTORE_STATUS="${BACKGROUND_RESTORE_STATUS:-0}"
    export CORE_ON_STATUS="${CORE_ON_STATUS:-0}"
    export CORE_OFF_STATUS="${CORE_OFF_STATUS:-0}"
    export CORE_EMERGENCY_STATUS="${CORE_EMERGENCY_STATUS:-0}"
    wrapper=$1
    shift
    /bin/sh "$wrapper" --requesting-uid 501 "$@"
}
WRAPPER_LOG="$TMP/log"; export WRAPPER_LOG

VALIDATE_STATUS=10 MEMORY_VALIDATE_STATUS=0 MEMORY_START_STATUS=0 BACKGROUND_APPLY_STATUS=0 CORE_ON_STATUS=0 run "$TMP/performance_on_with_priority.sh" --yes
assert_log 'memory:validate
priority:validate
background:apply
core:on
memory:start' 'ON ordering'

VALIDATE_STATUS=10 MEMORY_VALIDATE_STATUS=0 MEMORY_START_STATUS=0 BACKGROUND_APPLY_STATUS=20 CORE_ON_STATUS=0 run "$TMP/performance_on_with_priority.sh" --yes
assert_log 'memory:validate
priority:validate
background:apply
core:on
memory:start' 'verified rollback degrades without blocking core ON'

set +e
VALIDATE_STATUS=10 MEMORY_VALIDATE_STATUS=0 BACKGROUND_APPLY_STATUS=21 CORE_ON_STATUS=0 run "$TMP/performance_on_with_priority.sh" --yes >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 21 ] || fail 'unresolved partial settings mutation did not stop ON'
assert_log 'memory:validate
priority:validate
background:apply' 'unresolved settings prevented core ON'

set +e
VALIDATE_STATUS=10 MEMORY_VALIDATE_STATUS=0 BACKGROUND_APPLY_STATUS=0 CORE_ON_STATUS=1 BACKGROUND_RESTORE_STATUS=0 run "$TMP/performance_on_with_priority.sh" --yes >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail 'core ON failure returned zero'
assert_log 'memory:validate
priority:validate
background:apply
core:on
background:restore' 'core ON failure restored settings'

RESTORE_STATUS=11 MEMORY_RESTORE_STATUS=11 BACKGROUND_RESTORE_STATUS=0 CORE_OFF_STATUS=0 run "$TMP/performance_off_with_priority.sh"
assert_log 'memory:stop-and-restore
priority:stop-and-restore
background:restore
core:off' 'OFF restores memory, priority, and settings before core completion'

RESTORE_STATUS=11 MEMORY_RESTORE_STATUS=11 BACKGROUND_RESTORE_STATUS=0 CORE_EMERGENCY_STATUS=0 run "$TMP/emergency_restore_with_priority.sh" --yes
assert_log 'memory:stop-and-restore
priority:stop-and-restore
background:restore
core:emergency' 'Emergency restore includes memory and background settings'

grep -F 'CATALINA_PERFORMANCE_BACKGROUND_SERVICE_STATE_DIR' "$ROOT/scripts/lib/background_service_wrapper_common.sh" >/dev/null || fail 'state directory export missing'
grep -F 'CATALINA_PERFORMANCE_BACKGROUND_SERVICE_PUBLIC_STATUS_DIR' "$ROOT/scripts/lib/background_service_wrapper_common.sh" >/dev/null || fail 'public status directory export missing'
for file in "$ROOT/scripts/performance_on_with_priority.sh" "$ROOT/scripts/performance_off_with_priority.sh" "$ROOT/scripts/emergency_restore_with_priority.sh" "$ROOT/scripts/lib/background_service_wrapper_common.sh" "$ROOT/scripts/lib/memory_management_wrapper_common.sh"; do /bin/sh -n "$file" || fail "syntax: $file"; done
printf 'PASS: Background service wrappers\n'