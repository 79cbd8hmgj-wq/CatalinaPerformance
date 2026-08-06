#!/bin/sh
set -u

usage() {
    printf 'Usage: %s [--uid UID] [--output PATH]\n' "$0" >&2
}

requesting_uid=$(id -u)
output_path=

while [ "$#" -gt 0 ]; do
    case $1 in
        --uid)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            requesting_uid=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            output_path=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
done

case $requesting_uid in
    ''|*[!0-9]*)
        printf 'UID must contain decimal digits only.\n' >&2
        exit 2
        ;;
esac

DEFAULTS=${CP_DEFAULTS:-/usr/bin/defaults}
SW_VERS=${CP_SW_VERS:-/usr/bin/sw_vers}
SYSCTL=${CP_SYSCTL:-/usr/sbin/sysctl}
UNAME=${CP_UNAME:-/usr/bin/uname}

sanitize_line() {
    value=$(printf '%s' "$1" | tr '\r\n\t' '   ')
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf 'EMPTY\n'
    fi
}

command_value() {
    command_path=$1
    shift
    if [ -x "$command_path" ]; then
        "$command_path" "$@" 2>/dev/null || printf 'UNAVAILABLE\n'
    else
        printf 'UNAVAILABLE\n'
    fi
}

emit_candidate() {
    section=$1
    candidate_id=$2
    candidate_domain=$3
    candidate_key=$4

    printf '%s\n' "$section"
    printf 'candidate_id=%s\n' "$candidate_id"
    printf 'candidate_domain=%s\n' "$candidate_domain"
    printf 'candidate_key=%s\n' "$candidate_key"

    if [ ! -x "$DEFAULTS" ]; then
        printf 'read_status=127\n'
        printf 'read_type=ABSENT\n'
        printf 'read_value=ABSENT\n'
        printf '\n'
        return
    fi

    read_value=$($DEFAULTS read "$candidate_domain" "$candidate_key" 2>/dev/null)
    read_status=$?
    printf 'read_status=%s\n' "$read_status"

    if [ "$read_status" -ne 0 ]; then
        printf 'read_type=ABSENT\n'
        printf 'read_value=ABSENT\n'
        printf '\n'
        return
    fi

    read_type=$($DEFAULTS read-type "$candidate_domain" "$candidate_key" 2>/dev/null)
    read_type_status=$?
    if [ "$read_type_status" -eq 0 ]; then
        printf 'read_type=%s\n' "$(sanitize_line "$read_type")"
    else
        printf 'read_type=UNAVAILABLE(status=%s)\n' "$read_type_status"
    fi
    printf 'read_value=%s\n' "$(sanitize_line "$read_value")"
    printf '\n'
}

report_file=
cleanup_report=0
if [ -n "$output_path" ]; then
    output_directory=$(dirname -- "$output_path")
    [ -d "$output_directory" ] || {
        printf 'Output directory does not exist: %s\n' "$output_directory" >&2
        exit 1
    }
    report_file=$(mktemp "$output_directory/.visual-performance-probe.XXXXXX") || exit 1
    cleanup_report=1
else
    report_file=$(mktemp "${TMPDIR:-/tmp}/visual-performance-probe.XXXXXX") || exit 1
    cleanup_report=1
fi

trap '[ "$cleanup_report" -eq 1 ] && rm -f "$report_file"' EXIT HUP INT TERM

{
    printf 'VISUAL_PERFORMANCE_PROBE_SCHEMA=1\n'
    printf 'SYSTEM\n'
    printf 'os_name=%s\n' "$(command_value "$UNAME" -s | head -n 1)"
    printf 'os_version=%s\n' "$(command_value "$SW_VERS" -productVersion | head -n 1)"
    printf 'os_build=%s\n' "$(command_value "$SW_VERS" -buildVersion | head -n 1)"
    printf 'hardware_model=%s\n' "$(command_value "$SYSCTL" -n hw.model | head -n 1)"
    printf 'requesting_uid=%s\n' "$requesting_uid"
    printf 'current_uid=%s\n' "$(id -u)"
    printf '\n'

    emit_candidate 'DOCK_AUTO_HIDE' 'dockAutoHide' 'com.apple.dock' 'autohide'
    emit_candidate 'FINDER_ANIMATIONS' 'finderAnimations' 'com.apple.finder' 'DisableAllAnimations'
    emit_candidate 'DOCK_LAUNCH_ANIMATION' 'dockLaunchAnimation' 'com.apple.dock' 'launchanim'
    emit_candidate 'MISSION_CONTROL_TRANSITIONS' 'missionControlTransitions' 'com.apple.dock' 'expose-animation-duration'
    emit_candidate 'WINDOW_OPENING_ANIMATIONS' 'windowOpeningAnimations' 'NSGlobalDomain' 'NSAutomaticWindowAnimationsEnabled'
    emit_candidate 'REDUCE_MOTION' 'reduceMotion' 'com.apple.universalaccess' 'reduceMotion'
    emit_candidate 'REDUCE_TRANSPARENCY' 'reduceTransparency' 'com.apple.universalaccess' 'reduceTransparency'
    emit_candidate 'MINIMIZE_EFFECT' 'minimizeEffect' 'com.apple.dock' 'mineffect'
    emit_candidate 'DOCK_AUTO_HIDE_DELAY' 'dockAutoHideDelay' 'com.apple.dock' 'autohide-delay'
    emit_candidate 'DOCK_AUTO_HIDE_ANIMATION' 'dockAutoHideAnimation' 'com.apple.dock' 'autohide-time-modifier'
} > "$report_file"

cat "$report_file" >/dev/null 2>&1 || exit 1

if [ -n "$output_path" ]; then
    mv "$report_file" "$output_path"
    cleanup_report=0
    printf 'Visual Performance probe written to: %s\n' "$output_path"
else
    cat "$report_file"
fi
