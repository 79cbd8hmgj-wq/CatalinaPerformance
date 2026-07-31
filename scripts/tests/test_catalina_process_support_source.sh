#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SOURCE="$ROOT/app/CatalinaPerformance/Sources/CatalinaProcessSupport/CatalinaProcessSupport.c"

test -f "$SOURCE"
grep -F 'struct rusage_info_v2 usage;' "$SOURCE" >/dev/null
! grep -E '^[[:space:]]*rusage_info_v2[[:space:]]+usage;' "$SOURCE" >/dev/null

grep -F 'struct proc_taskinfo task;' "$SOURCE" >/dev/null
grep -F 'PROC_PIDTASKINFO' "$SOURCE" >/dev/null
grep -F 'task.pti_resident_size' "$SOURCE" >/dev/null
! grep -F 'usage.ri_resident_size' "$SOURCE" >/dev/null

grep -F 'stats.free_count' "$SOURCE" >/dev/null
grep -F 'stats.inactive_count' "$SOURCE" >/dev/null
! grep -F 'stats.speculative_count' "$SOURCE" >/dev/null

printf 'PASS: Catalina process-support source contract\n'
