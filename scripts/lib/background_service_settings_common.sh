#!/bin/sh

BACKGROUND_SERVICE_DEFAULTS_BIN=${BACKGROUND_SERVICE_DEFAULTS_BIN:-/usr/bin/defaults}
BACKGROUND_SERVICE_PYTHON_BIN=${BACKGROUND_SERVICE_PYTHON_BIN:-/usr/bin/python}
BACKGROUND_SERVICE_SUDO_BIN=${BACKGROUND_SERVICE_SUDO_BIN:-/usr/bin/sudo}
BACKGROUND_SERVICE_CHOWN_BIN=${BACKGROUND_SERVICE_CHOWN_BIN:-/usr/sbin/chown}

background_service_settings_init() {
    if [ -n "${CATALINA_PERFORMANCE_BACKGROUND_SERVICE_STATE_DIR:-}" ]; then
        BACKGROUND_SERVICE_ROOT=$CATALINA_PERFORMANCE_BACKGROUND_SERVICE_STATE_DIR
    elif [ -n "${CATALINA_PERFORMANCE_STATE_DIR:-}" ]; then
        BACKGROUND_SERVICE_ROOT=$CATALINA_PERFORMANCE_STATE_DIR/background_service_suppression
    else
        return 1
    fi
    BACKGROUND_SERVICE_SETTINGS_DIR=$BACKGROUND_SERVICE_ROOT/settings
    BACKGROUND_SERVICE_STATUS_FILE=$BACKGROUND_SERVICE_SETTINGS_DIR/settings-status.json
    if [ -n "${CATALINA_PERFORMANCE_BACKGROUND_SERVICE_PUBLIC_STATUS_DIR:-}" ]; then
        BACKGROUND_SERVICE_PUBLIC_STATUS_DIR=$CATALINA_PERFORMANCE_BACKGROUND_SERVICE_PUBLIC_STATUS_DIR
    else
        BACKGROUND_SERVICE_PUBLIC_STATUS_DIR=$BACKGROUND_SERVICE_ROOT/public-status
    fi
    BACKGROUND_SERVICE_PUBLIC_STATUS_FILE=$BACKGROUND_SERVICE_PUBLIC_STATUS_DIR/settings-status.json
    mkdir -p "$BACKGROUND_SERVICE_SETTINGS_DIR" || return 1
    chmod 700 "$BACKGROUND_SERVICE_ROOT" "$BACKGROUND_SERVICE_SETTINGS_DIR" 2>/dev/null || true
    return 0
}

background_service_prepare_public_status_dir() {
    [ ! -L "$BACKGROUND_SERVICE_PUBLIC_STATUS_DIR" ] || return 1
    mkdir -p "$BACKGROUND_SERVICE_PUBLIC_STATUS_DIR" || return 1
    [ ! -L "$BACKGROUND_SERVICE_PUBLIC_STATUS_DIR" ] || return 1
    chmod 700 "$BACKGROUND_SERVICE_PUBLIC_STATUS_DIR" 2>/dev/null || return 1
    if [ "${BACKGROUND_SERVICE_TEST_MODE:-0}" != "1" ]; then
        "$BACKGROUND_SERVICE_CHOWN_BIN" "$REQUESTING_UID" "$BACKGROUND_SERVICE_PUBLIC_STATUS_DIR" || return 1
    fi
    return 0
}

background_service_validate_uid() {
    case ${1:-} in
        ''|*[!0-9]*|0) return 1 ;;
        *) REQUESTING_UID=$1; return 0 ;;
    esac
}

background_service_supported_pair() {
    domain=$1
    key=$2
    case "$domain:$key" in
        /Library/Preferences/com.apple.SoftwareUpdate:AutomaticCheckEnabled|\
        /Library/Preferences/com.apple.SoftwareUpdate:AutomaticDownload|\
        /Library/Preferences/com.apple.SoftwareUpdate:AutomaticallyInstallMacOSUpdates|\
        com.apple.commerce:AutoUpdate|\
        com.apple.commerce:AutoUpdateRestartRequired)
            return 0
            ;;
        test.background.services:BoolKey|\
        test.background.services:IntKey|\
        test.background.services:StringKey)
            [ "${BACKGROUND_SERVICE_TEST_MODE:-0}" = "1" ]
            return $?
            ;;
        *) return 1 ;;
    esac
}

background_service_domain_scope() {
    case "$1" in
        /Library/Preferences/com.apple.SoftwareUpdate) printf 'system\n' ;;
        com.apple.commerce|test.background.services) printf 'user\n' ;;
        *) return 1 ;;
    esac
}

background_service_defaults() {
    domain=$1
    shift
    scope=$(background_service_domain_scope "$domain") || return 1
    if [ "$scope" = system ] || [ "${BACKGROUND_SERVICE_TEST_MODE:-0}" = "1" ]; then
        "$BACKGROUND_SERVICE_DEFAULTS_BIN" "$@" "$domain"
        return $?
    fi
    current_uid=$(/usr/bin/id -u 2>/dev/null || /bin/id -u 2>/dev/null || printf '0')
    if [ "$current_uid" = "$REQUESTING_UID" ]; then
        "$BACKGROUND_SERVICE_DEFAULTS_BIN" "$@" "$domain"
    else
        "$BACKGROUND_SERVICE_SUDO_BIN" -u "#$REQUESTING_UID" -H "$BACKGROUND_SERVICE_DEFAULTS_BIN" "$@" "$domain"
    fi
}

background_service_defaults_read_type() {
    domain=$1 key=$2
    scope=$(background_service_domain_scope "$domain") || return 1
    if [ "$scope" = system ] || [ "${BACKGROUND_SERVICE_TEST_MODE:-0}" = "1" ]; then
        "$BACKGROUND_SERVICE_DEFAULTS_BIN" read-type "$domain" "$key"
    else
        current_uid=$(/usr/bin/id -u 2>/dev/null || /bin/id -u 2>/dev/null || printf '0')
        if [ "$current_uid" = "$REQUESTING_UID" ]; then
            "$BACKGROUND_SERVICE_DEFAULTS_BIN" read-type "$domain" "$key"
        else
            "$BACKGROUND_SERVICE_SUDO_BIN" -u "#$REQUESTING_UID" -H "$BACKGROUND_SERVICE_DEFAULTS_BIN" read-type "$domain" "$key"
        fi
    fi
}

background_service_defaults_read() {
    domain=$1 key=$2
    scope=$(background_service_domain_scope "$domain") || return 1
    if [ "$scope" = system ] || [ "${BACKGROUND_SERVICE_TEST_MODE:-0}" = "1" ]; then
        "$BACKGROUND_SERVICE_DEFAULTS_BIN" read "$domain" "$key"
    else
        current_uid=$(/usr/bin/id -u 2>/dev/null || /bin/id -u 2>/dev/null || printf '0')
        if [ "$current_uid" = "$REQUESTING_UID" ]; then
            "$BACKGROUND_SERVICE_DEFAULTS_BIN" read "$domain" "$key"
        else
            "$BACKGROUND_SERVICE_SUDO_BIN" -u "#$REQUESTING_UID" -H "$BACKGROUND_SERVICE_DEFAULTS_BIN" read "$domain" "$key"
        fi
    fi
}

background_service_defaults_write() {
    domain=$1 key=$2 type=$3 value=$4
    scope=$(background_service_domain_scope "$domain") || return 1
    case "$type" in
        bool)
            type_flag=-bool
            value=$(background_service_normalize_boolean "$value") || return 1
            ;;
        int) type_flag=-int ;;
        string) type_flag=-string ;;
        *) return 1 ;;
    esac
    if [ "$scope" = system ] || [ "${BACKGROUND_SERVICE_TEST_MODE:-0}" = "1" ]; then
        "$BACKGROUND_SERVICE_DEFAULTS_BIN" write "$domain" "$key" "$type_flag" "$value"
    else
        current_uid=$(/usr/bin/id -u 2>/dev/null || /bin/id -u 2>/dev/null || printf '0')
        if [ "$current_uid" = "$REQUESTING_UID" ]; then
            "$BACKGROUND_SERVICE_DEFAULTS_BIN" write "$domain" "$key" "$type_flag" "$value"
        else
            "$BACKGROUND_SERVICE_SUDO_BIN" -u "#$REQUESTING_UID" -H "$BACKGROUND_SERVICE_DEFAULTS_BIN" write "$domain" "$key" "$type_flag" "$value"
        fi
    fi
}

background_service_defaults_delete() {
    domain=$1 key=$2
    scope=$(background_service_domain_scope "$domain") || return 1
    if [ "$scope" = system ] || [ "${BACKGROUND_SERVICE_TEST_MODE:-0}" = "1" ]; then
        "$BACKGROUND_SERVICE_DEFAULTS_BIN" delete "$domain" "$key"
    else
        current_uid=$(/usr/bin/id -u 2>/dev/null || /bin/id -u 2>/dev/null || printf '0')
        if [ "$current_uid" = "$REQUESTING_UID" ]; then
            "$BACKGROUND_SERVICE_DEFAULTS_BIN" delete "$domain" "$key"
        else
            "$BACKGROUND_SERVICE_SUDO_BIN" -u "#$REQUESTING_UID" -H "$BACKGROUND_SERVICE_DEFAULTS_BIN" delete "$domain" "$key"
        fi
    fi
}

background_service_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

capture_preference_key() {
    domain=$1 key=$2 output_file=$3
    background_service_supported_pair "$domain" "$key" || return 1
    [ ! -L "$output_file" ] || return 1
    type_output=$(background_service_defaults_read_type "$domain" "$key" 2>/dev/null) || type_output=
    if [ -z "$type_output" ]; then
        was_present=false
        value_type=missing
        value=
    else
        was_present=true
        case "$type_output" in
            *Boolean*|*boolean*) value_type=bool ;;
            *Integer*|*integer*) value_type=int ;;
            *String*|*string*) value_type=string ;;
            *) return 1 ;;
        esac
        value=$(background_service_defaults_read "$domain" "$key" 2>/dev/null) || return 1
    fi
    tmp=$output_file.tmp.$$
    umask 077
    {
        printf '{"domain":"%s","key":"%s","wasPresent":%s,"type":"%s","value":"%s"}\n' \
            "$(background_service_json_escape "$domain")" \
            "$(background_service_json_escape "$key")" \
            "$was_present" "$value_type" "$(background_service_json_escape "$value")"
    } > "$tmp" || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$output_file"
}

write_boolean_preference() {
    domain=$1 key=$2 value=$3
    background_service_supported_pair "$domain" "$key" || return 1
    case "$value" in true|false) ;; *) return 1 ;; esac
    background_service_defaults_write "$domain" "$key" bool "$value"
}

background_service_snapshot_field() {
    file=$1 field=$2
    sed -n 's/.*"'"$field"'":"\([^"]*\)".*/\1/p' "$file" | head -n 1
}

background_service_snapshot_boolean() {
    file=$1 field=$2
    sed -n 's/.*"'"$field"'":\(true\|false\).*/\1/p' "$file" | head -n 1
}

restore_preference_key() {
    domain=$1 key=$2 snapshot_file=$3
    background_service_supported_pair "$domain" "$key" || return 1
    [ -f "$snapshot_file" ] && [ ! -L "$snapshot_file" ] || return 1
    stored_domain=$(background_service_snapshot_field "$snapshot_file" domain)
    stored_key=$(background_service_snapshot_field "$snapshot_file" key)
    [ "$stored_domain" = "$domain" ] && [ "$stored_key" = "$key" ] || return 1
    was_present=$(background_service_snapshot_boolean "$snapshot_file" wasPresent)
    if [ "$was_present" = false ]; then
        background_service_defaults_delete "$domain" "$key" >/dev/null 2>&1 || true
        if background_service_defaults_read_type "$domain" "$key" >/dev/null 2>&1; then return 1; fi
        return 0
    fi
    [ "$was_present" = true ] || return 1
    value_type=$(background_service_snapshot_field "$snapshot_file" type)
    value=$(background_service_snapshot_field "$snapshot_file" value)
    background_service_defaults_write "$domain" "$key" "$value_type" "$value" || return 1
    verify_preference_value "$domain" "$key" "$value_type" "$value"
}

background_service_normalize_boolean() {
    case "$1" in
        true|TRUE|True|yes|YES|Yes|1) printf 'true\n' ;;
        false|FALSE|False|no|NO|No|0) printf 'false\n' ;;
        *) return 1 ;;
    esac
}

verify_preference_value() {
    domain=$1 key=$2 expected_type=$3 expected_value=$4
    observed_type=$(background_service_defaults_read_type "$domain" "$key" 2>/dev/null) || return 1
    case "$expected_type:$observed_type" in
        bool:*Boolean*|bool:*boolean*|int:*Integer*|int:*integer*|string:*String*|string:*string*) ;;
        *) return 1 ;;
    esac
    observed=$(background_service_defaults_read "$domain" "$key" 2>/dev/null) || return 1
    if [ "$expected_type" = bool ]; then
        expected_boolean=$(background_service_normalize_boolean "$expected_value") || return 1
        observed_boolean=$(background_service_normalize_boolean "$observed") || return 1
        [ "$observed_boolean" = "$expected_boolean" ]
        return $?
    fi
    [ "$observed" = "$expected_value" ]
}

verify_boolean_preference() {
    verify_preference_value "$1" "$2" bool "$3"
}

background_service_emit_settings_status() {
    state=$1 note=$2 category1_state=$3 category2_state=$4
    note_escaped=$(background_service_json_escape "$note")
    printf '{"schemaVersion":1,"categories":['
    printf '{"category":"softwareUpdate","state":"%s","note":"%s"},' "$category1_state" "$note_escaped"
    printf '{"category":"appStoreUpdates","state":"%s","note":"%s"}' "$category2_state" "$note_escaped"
    printf ']}\n'
}

write_settings_status() {
    state=$1 note=${2:-}
    category1_state=${3:-$state}
    category2_state=${4:-$state}
    private_tmp=$BACKGROUND_SERVICE_STATUS_FILE.tmp.$$
    public_tmp=$BACKGROUND_SERVICE_PUBLIC_STATUS_FILE.tmp.$$
    umask 077

    [ ! -L "$BACKGROUND_SERVICE_STATUS_FILE" ] || return 1
    background_service_emit_settings_status "$state" "$note" "$category1_state" "$category2_state" > "$private_tmp" || return 1
    chmod 600 "$private_tmp" 2>/dev/null || true
    mv -f "$private_tmp" "$BACKGROUND_SERVICE_STATUS_FILE" || return 1

    background_service_prepare_public_status_dir || return 1
    [ ! -L "$BACKGROUND_SERVICE_PUBLIC_STATUS_FILE" ] || return 1
    background_service_emit_settings_status "$state" "$note" "$category1_state" "$category2_state" > "$public_tmp" || return 1
    chmod 600 "$public_tmp" 2>/dev/null || true
    if [ "${BACKGROUND_SERVICE_TEST_MODE:-0}" != "1" ]; then
        "$BACKGROUND_SERVICE_CHOWN_BIN" "$REQUESTING_UID" "$public_tmp" || { rm -f "$public_tmp"; return 1; }
    fi
    mv -f "$public_tmp" "$BACKGROUND_SERVICE_PUBLIC_STATUS_FILE"
}
