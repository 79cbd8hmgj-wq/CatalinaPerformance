#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROBE="$ROOT/scripts/memory_vm_probe.sh"

test -f "$PROBE"

grep -F '/usr/bin/vm_stat' "$PROBE" >/dev/null
grep -F '/usr/bin/memory_pressure' "$PROBE" >/dev/null
grep -F '/usr/sbin/sysctl' "$PROBE" >/dev/null
grep -F 'hw.memsize' "$PROBE" >/dev/null
grep -F 'vm.swapusage' "$PROBE" >/dev/null
grep -F 'sleep 2' "$PROBE" >/dev/null

grep -F -- '--output' "$PROBE" >/dev/null
! grep -Eq '(^|[[:space:]])sudo([[:space:]]|$)' "$PROBE"
! grep -Eq '(^|[[:space:]])purge([[:space:]]|$)' "$PROBE"
! grep -Eq 'killall|launchctl[[:space:]]+(bootout|unload|disable)|sysctl[[:space:]]+-w|rm[[:space:]].*swap' "$PROBE"
! grep -Eq 'defaults[[:space:]]+(write|delete)' "$PROBE"

printf 'PASS: Memory VM probe source contract\n'
