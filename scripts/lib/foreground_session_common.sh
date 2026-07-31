#!/bin/sh

# Shared, user-level helpers for Foreground Performance Session scripts.
# This file is sourced; it deliberately does not enable `set -e` for callers.

CP_OSASCRIPT=${CATALINA_PERFORMANCE_OSASCRIPT_BIN:-/usr/bin/osascript}
CP_DEFAULTS=${CATALINA_PERFORMANCE_DEFAULTS_BIN:-/usr/bin/defaults}
CP_OPEN=${CATALINA_PERFORMANCE_OPEN_BIN:-/usr/bin/open}

cp_foreground_root() {
    if [ -n "${CATALINA_PERFORMANCE_FOREGROUND_DIR:-}" ]; then
        printf '%s\n' "$CATALINA_PERFORMANCE_FOREGROUND_DIR"
    else
        printf '%s\n' "$HOME/Library/Application Support/CatalinaPerformance/foreground_session"
    fi
}

cp_preferences_file() {
    if [ -n "${CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE:-}" ]; then
        printf '%s\n' "$CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE"
    else
        printf '%s/preferences.env\n' "$(cp_foreground_root)"
    fi
}

cp_runtime_dir() {
    printf '%s/runtime\n' "$(cp_foreground_root)"
}

cp_logs_dir() {
    printf '%s/logs\n' "$(cp_foreground_root)"
}

cp_validate_bundle_id() {
    case ${1:-} in
        ''|*[!A-Za-z0-9.-]*|.*|*..*|*.) return 1 ;;
        *) return 0 ;;
    esac
}

cp_is_excluded_bundle_id() {
    case ${1:-} in
        local.CatalinaPerformance|org.swift.CatalinaPerformance|com.apple.Terminal|com.googlecode.iterm2|com.googlecode.iterm2.*|com.apple.finder|com.apple.dock|com.apple.systemuiserver|com.apple.WindowServer|com.apple.loginwindow)
            return 0
            ;;
        *) return 1 ;;
    esac
}

cp_sanitize_tsv_field() {
    # Runtime values are metadata only. Collapse tabs/newlines so every state row
    # keeps a fixed number of columns and can never become executable input.
    printf '%s' "${1:-}" | tr '\t\r\n' '   '
}

cp_trim() {
    printf '%s\n' "${1:-}" | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }'
}

cp_read_boolean_preference() {
    cp_key=$1
    cp_default=$2
    cp_file=$(cp_preferences_file)
    cp_value=
    if [ -r "$cp_file" ]; then
        cp_value=$(awk -F= -v key="$cp_key" '
            $1 == key {
                value = substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                result = value
            }
            END { print result }
        ' "$cp_file")
    fi
    case $cp_value in
        1|true|TRUE|yes|YES|on|ON) printf '1\n' ;;
        0|false|FALSE|no|NO|off|OFF) printf '0\n' ;;
        *) printf '%s\n' "$cp_default" ;;
    esac
}

cp_selected_bundle_ids() {
    cp_file=$(cp_preferences_file)
    [ -r "$cp_file" ] || return 0
    awk -F= '$1 == "SELECTED_BUNDLE_ID" { print substr($0, index($0, "=") + 1) }' "$cp_file" |
    while IFS= read -r cp_raw; do
        cp_id=$(cp_trim "$cp_raw")
        if cp_validate_bundle_id "$cp_id" && ! cp_is_excluded_bundle_id "$cp_id"; then
            printf '%s\n' "$cp_id"
        fi
    done | awk 'NF && !seen[$0]++' | LC_ALL=C sort
}

cp_prepare_storage() {
    cp_root=$(cp_foreground_root)
    cp_runtime=$(cp_runtime_dir)
    cp_logs=$(cp_logs_dir)
    umask 077
    mkdir -p "$cp_root" "$cp_runtime" "$cp_logs" || return 1
    chmod 700 "$cp_root" "$cp_runtime" "$cp_logs" 2>/dev/null || true
    cp_probe="$cp_runtime/.write_probe.$$"
    printf 'CatalinaPerformance storage probe\n' > "$cp_probe" || return 1
    cp_probe_value=$(cat "$cp_probe" 2>/dev/null) || {
        rm -f "$cp_probe"
        return 1
    }
    rm -f "$cp_probe" || return 1
    [ "$cp_probe_value" = "CatalinaPerformance storage probe" ]
}

cp_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

cp_session_is_active() {
    cp_session_file="$(cp_runtime_dir)/session.env"
    [ -r "$cp_session_file" ] || return 1
    awk -F= '$1 == "SESSION_ACTIVE" && $2 == "1" { found=1 } END { exit(found ? 0 : 1) }' "$cp_session_file"
}

cp_write_session_active() {
    cp_active=$1
    cp_session_file="$(cp_runtime_dir)/session.env"
    cp_tmp="$cp_session_file.tmp.$$"
    cp_id=${2:-$(date '+%Y%m%d%H%M%S').$$}
    {
        printf 'SESSION_ACTIVE=%s\n' "$cp_active"
        printf 'SESSION_ID=%s\n' "$cp_id"
        printf 'UPDATED_AT=%s\n' "$(cp_timestamp)"
    } > "$cp_tmp" || return 1
    cat "$cp_tmp" >/dev/null 2>&1 || { rm -f "$cp_tmp"; return 1; }
    mv "$cp_tmp" "$cp_session_file"
}

cp_application_is_running() {
    cp_bundle_id=$1
    cp_validate_bundle_id "$cp_bundle_id" || return 1
    cp_result=$($CP_OSASCRIPT -e "application id \"$cp_bundle_id\" is running" 2>/dev/null || printf 'false')
    [ "$cp_result" = "true" ]
}

cp_request_graceful_quit() {
    cp_bundle_id=$1
    cp_validate_bundle_id "$cp_bundle_id" || return 1
    $CP_OSASCRIPT -e "tell application id \"$cp_bundle_id\" to quit" >/dev/null 2>&1
}

cp_application_display_name() {
    cp_bundle_id=$1
    cp_validate_bundle_id "$cp_bundle_id" || return 1
    cp_name=$($CP_OSASCRIPT -e "name of application id \"$cp_bundle_id\"" 2>/dev/null || true)
    [ -n "$cp_name" ] || cp_name=$cp_bundle_id
    cp_sanitize_tsv_field "$cp_name"
}

cp_log() {
    cp_log_file=$1
    shift
    printf '%s %s\n' "$(cp_timestamp)" "$*" >> "$cp_log_file"
}
