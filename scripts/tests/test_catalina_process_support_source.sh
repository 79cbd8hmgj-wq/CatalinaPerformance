#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SOURCE="$ROOT/app/CatalinaPerformance/Sources/CatalinaProcessSupport/CatalinaProcessSupport.c"
HEADER="$ROOT/app/CatalinaPerformance/Sources/CatalinaProcessSupport/include/CatalinaProcessSupport.h"

test -f "$SOURCE"
test -f "$HEADER"
grep -F 'struct rusage_info_v2 usage;' "$SOURCE" >/dev/null
! grep -E '^[[:space:]]*rusage_info_v2[[:space:]]+usage;' "$SOURCE" >/dev/null

grep -F 'struct proc_taskinfo task;' "$SOURCE" >/dev/null
grep -F 'PROC_PIDTASKINFO' "$SOURCE" >/dev/null
grep -F 'task.pti_resident_size' "$SOURCE" >/dev/null
! grep -F 'usage.ri_resident_size' "$SOURCE" >/dev/null

grep -F 'stats.free_count' "$SOURCE" >/dev/null
grep -F 'stats.inactive_count' "$SOURCE" >/dev/null
! grep -F 'stats.speculative_count' "$SOURCE" >/dev/null

grep -F 'CP_PROCESS_ARGUMENTS_MAX 16384' "$HEADER" >/dev/null
grep -F 'cp_read_process_arguments' "$HEADER" >/dev/null
grep -F 'KERN_PROCARGS2' "$SOURCE" >/dev/null
grep -F 'capacity > CP_PROCESS_ARGUMENTS_MAX' "$SOURCE" >/dev/null
grep -F 'memchr' "$SOURCE" >/dev/null
grep -F 'return -E2BIG;' "$SOURCE" >/dev/null
! grep -E '/bin/ps|popen[[:space:]]*\(|system[[:space:]]*\(' "$SOURCE" >/dev/null

printf 'PASS: Catalina process-support source contract\n'
