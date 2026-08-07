#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SOURCE_DIR="$ROOT/app/CatalinaPerformance/Sources/CatalinaProcessSupport"
SOURCE="$SOURCE_DIR/CatalinaProcessSupport.c"
HEADER="$SOURCE_DIR/include/CatalinaProcessSupport.h"

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

VM_DEFINITION_FILE_COUNT=$(grep -l -E '^[[:space:]]*int32_t[[:space:]]+cp_read_vm_memory_info[[:space:]]*\(' "$SOURCE_DIR"/*.c | wc -l | tr -d ' ')
if [ "$VM_DEFINITION_FILE_COUNT" -ne 1 ]; then
    printf 'Expected cp_read_vm_memory_info in exactly one C translation unit; found %s.\n' "$VM_DEFINITION_FILE_COUNT" >&2
    exit 1
fi

printf 'PASS: Catalina process-support source contract\n'
