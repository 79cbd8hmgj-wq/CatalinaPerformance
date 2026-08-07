#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/memory_taskpolicy_calibration.sh"

test -f "$SCRIPT"

grep -F '/usr/bin/taskpolicy' "$SCRIPT" >/dev/null
grep -F '/bin/sleep 30 &' "$SCRIPT" >/dev/null
grep -F 'CHILD_PID=$!' "$SCRIPT" >/dev/null
grep -F '/usr/bin/taskpolicy -p "$CHILD_PID"' "$SCRIPT" >/dev/null
grep -F '/usr/bin/taskpolicy -b -p "$CHILD_PID"' "$SCRIPT" >/dev/null
grep -F '/usr/bin/taskpolicy -B -p "$CHILD_PID"' "$SCRIPT" >/dev/null
grep -F '/bin/kill "$CHILD_PID"' "$SCRIPT" >/dev/null

! grep -Eq -- '--pid|--target-pid|TARGET_PID=' "$SCRIPT"
! grep -Eq '(^|[[:space:]])sudo([[:space:]]|$)' "$SCRIPT"
! grep -Eq 'launchctl|LaunchDaemon|LaunchAgent|nohup' "$SCRIPT"
! grep -Eq 'killall|pkill' "$SCRIPT"
! grep -Eq '/bin/kill[[:space:]]+[^"$]' "$SCRIPT"

printf 'PASS: Memory taskpolicy calibration source contract\n'
