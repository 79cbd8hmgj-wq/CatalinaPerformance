#!/bin/sh
set -u

usage() {
    printf 'Usage: %s --output <path>\n' "$0"
}

OUTPUT=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            [ "$#" -ge 2 ] || { printf 'Missing value for --output.\n' >&2; exit 2; }
            OUTPUT=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ -n "$OUTPUT" ] || { printf 'Missing --output.\n' >&2; usage >&2; exit 2; }

OUTPUT_DIR=$(dirname -- "$OUTPUT")
[ -d "$OUTPUT_DIR" ] || { printf 'Output directory does not exist: %s\n' "$OUTPUT_DIR" >&2; exit 2; }

umask 077
: > "$OUTPUT" || { printf 'Unable to create output file: %s\n' "$OUTPUT" >&2; exit 1; }

section() {
    printf '\n===== %s =====\n' "$1" >> "$OUTPUT"
}

capture() {
    label=$1
    shift
    section "$label"
    if "$@" >> "$OUTPUT" 2>&1; then
        return 0
    fi
    status=$?
    printf '[command exited with status %s]\n' "$status" >> "$OUTPUT"
    return 0
}

section 'CatalinaPerformance Memory VM Capability Probe'
printf 'This probe is read-only. It does not use sudo, change sysctls, purge memory, or modify preferences.\n' >> "$OUTPUT"
printf 'Captured at: ' >> "$OUTPUT"
/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' >> "$OUTPUT" 2>&1 || true

capture 'macOS version' /usr/bin/sw_vers
capture 'Kernel' /usr/bin/uname -a
capture 'Physical memory' /usr/sbin/sysctl hw.memsize
capture 'Hardware page size' /usr/sbin/sysctl hw.pagesize
capture 'Swap usage' /usr/sbin/sysctl vm.swapusage
capture 'memory_pressure' /usr/bin/memory_pressure

section 'Selected read-only VM sysctls'
for key in \
    vm.compressor_mode \
    vm.page_free_target \
    vm.page_free_min \
    vm.pageout_stat_now \
    vm.memory_pressure
do
    printf '\n$ /usr/sbin/sysctl %s\n' "$key" >> "$OUTPUT"
    if /usr/sbin/sysctl "$key" >> "$OUTPUT" 2>&1; then
        :
    else
        status=$?
        printf '[unavailable or exited with status %s]\n' "$status" >> "$OUTPUT"
    fi
done

index=1
while [ "$index" -le 3 ]; do
    capture "vm_stat sample $index of 3" /usr/bin/vm_stat
    if [ "$index" -lt 3 ]; then
        /bin/sleep 2
    fi
    index=$((index + 1))
done

section 'Probe complete'
printf 'Review counter names, units, availability, monotonic behavior, and idle/pressure ranges before enabling production rate thresholds.\n' >> "$OUTPUT"
printf 'Wrote read-only VM evidence to %s\n' "$OUTPUT"
