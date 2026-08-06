#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cp-bg-settings.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
FAKE_DB=$TMP/db
STATE=$TMP/state
mkdir -p "$FAKE_DB" "$STATE" "$TMP/bin"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected=$2 actual=$1)"; }

cat > "$TMP/bin/defaults" <<'FAKE'
#!/bin/sh
set -u
DB=${FAKE_DEFAULTS_DB:?}
cmd=$1; shift
sanitize() { printf '%s' "$1" | sed 's#[/ ]#_#g; s#[^A-Za-z0-9_.-]#_#g'; }
case "$cmd" in
    read-type)
        domain=$1 key=$2 file="$DB/$(sanitize "$domain")__$(sanitize "$key")"
        [ -f "$file" ] || exit 1
        type=$(sed -n '1p' "$file")
        case "$type" in bool) printf 'Type is boolean\n' ;; int) printf 'Type is integer\n' ;; string) printf 'Type is string\n' ;; *) exit 1 ;; esac
        ;;
    read)
        domain=$1 key=$2 file="$DB/$(sanitize "$domain")__$(sanitize "$key")"
        [ -f "$file" ] || exit 1
        type=$(sed -n '1p' "$file")
        value=$(sed -n '2p' "$file")
        if [ "$type" = bool ]; then
            if [ "${FAKE_DEFAULTS_MISMATCH_ONCE_KEY:-}" = "$key" ] &&
               [ -f "$DB/.written-$key" ] &&
               [ ! -f "$DB/.mismatch-consumed-$key" ]; then
                : > "$DB/.mismatch-consumed-$key"
                case "$value" in true|1) printf '0\n' ;; false|0) printf '1\n' ;; *) exit 1 ;; esac
                exit 0
            fi
            case "$value" in true|1) printf '1\n' ;; false|0) printf '0\n' ;; *) exit 1 ;; esac
        else
            printf '%s\n' "$value"
        fi
        ;;
    write)
        domain=$1 key=$2 flag=$3 value=$4
        [ "${FAKE_DEFAULTS_FAIL_KEY:-}" != "$key" ] || exit 7
        file="$DB/$(sanitize "$domain")__$(sanitize "$key")"
        case "$flag" in
            -bool)
                type=bool
                case "$value" in
                    true|yes) value=1 ;;
                    false|no) value=0 ;;
                    *) exit 2 ;;
                esac
                ;;
            -int) type=int ;;
            -string) type=string ;;
            *) exit 2 ;;
        esac
        { printf '%s\n' "$type"; printf '%s\n' "$value"; } > "$file"
        : > "$DB/.written-$key"
        ;;
    delete)
        domain=$1 key=$2 file="$DB/$(sanitize "$domain")__$(sanitize "$key")"
        rm -f "$file"
        ;;
    *) exit 2 ;;
esac
FAKE
chmod +x "$TMP/bin/defaults"

put_value() {
    domain=$1 key=$2 type=$3 value=$4
    name=$(printf '%s' "$domain" | sed 's#[/ ]#_#g; s#[^A-Za-z0-9_.-]#_#g')__$(printf '%s' "$key" | sed 's#[/ ]#_#g; s#[^A-Za-z0-9_.-]#_#g')
    { printf '%s\n' "$type"; printf '%s\n' "$value"; } > "$FAKE_DB/$name"
}
get_value() {
    domain=$1 key=$2
    name=$(printf '%s' "$domain" | sed 's#[/ ]#_#g; s#[^A-Za-z0-9_.-]#_#g')__$(printf '%s' "$key" | sed 's#[/ ]#_#g; s#[^A-Za-z0-9_.-]#_#g')
    [ -f "$FAKE_DB/$name" ] || { printf 'MISSING\n'; return; }
    sed -n '2p' "$FAKE_DB/$name"
}

export BACKGROUND_SERVICE_TEST_MODE=1
export BACKGROUND_SERVICE_DEFAULTS_BIN="$TMP/bin/defaults"
export FAKE_DEFAULTS_DB="$FAKE_DB"
export CATALINA_PERFORMANCE_BACKGROUND_SERVICE_STATE_DIR="$STATE"
PUBLIC_STATUS=$TMP/public-status
export CATALINA_PERFORMANCE_BACKGROUND_SERVICE_PUBLIC_STATUS_DIR="$PUBLIC_STATUS"

put_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled bool true
put_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload bool false
# AutomaticallyInstallMacOSUpdates intentionally missing.
put_value com.apple.commerce AutoUpdate bool false
put_value com.apple.commerce AutoUpdateRestartRequired bool true

"$ROOT/scripts/background_service_settings_apply.sh" --requesting-uid 501
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled)" 0 "software update check not paused"
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload)" 0 "software update download not paused"
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates)" 0 "missing install key not temporarily created"
assert_eq "$(get_value com.apple.commerce AutoUpdate)" 0 "App Store auto update not paused"
assert_eq "$(get_value com.apple.commerce AutoUpdateRestartRequired)" 0 "App Store restart update not paused"
grep -F '"state":"paused"' "$STATE/settings/settings-status.json" >/dev/null || fail "paused private status missing"
grep -F '"state":"paused"' "$PUBLIC_STATUS/settings-status.json" >/dev/null || fail "paused public status missing"
[ ! -L "$PUBLIC_STATUS/settings-status.json" ] || fail "public status is a symbolic link"

"$ROOT/scripts/background_service_settings_restore.sh" --requesting-uid 501
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled)" 1 "software update check not restored"
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload)" 0 "software update download changed during restore"
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates)" MISSING "missing key was not deleted on restore"
assert_eq "$(get_value com.apple.commerce AutoUpdate)" 0 "App Store auto update not restored"
assert_eq "$(get_value com.apple.commerce AutoUpdateRestartRequired)" 1 "App Store restart flag not restored"
grep -F '"state":"restored"' "$STATE/settings/settings-status.json" >/dev/null || fail "restored status missing"


# A write that succeeds but fails verification must still be tracked and rolled back.
rm -rf "$STATE/settings" "$PUBLIC_STATUS"; mkdir -p "$STATE/settings"
put_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled bool true
put_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload bool false
put_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates bool false
put_value com.apple.commerce AutoUpdate bool false
put_value com.apple.commerce AutoUpdateRestartRequired bool false
rm -f "$FAKE_DB/.written-AutomaticCheckEnabled" "$FAKE_DB/.mismatch-consumed-AutomaticCheckEnabled"
export FAKE_DEFAULTS_MISMATCH_ONCE_KEY=AutomaticCheckEnabled
set +e
"$ROOT/scripts/background_service_settings_apply.sh" --requesting-uid 501
status=$?
set -e
unset FAKE_DEFAULTS_MISMATCH_ONCE_KEY
assert_eq "$status" 20 "verification failure did not report verified rollback"
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled)" 1 "verification failure lost original boolean value"
grep -F '"state":"rolledBack"' "$PUBLIC_STATUS/settings-status.json" >/dev/null || fail "public rollback status missing"

# Generic helper preserves supported test-only boolean/integer/string types.
. "$ROOT/scripts/lib/background_service_settings_common.sh"
REQUESTING_UID=501
background_service_settings_init
put_value test.background.services BoolKey bool true
put_value test.background.services IntKey int 42
put_value test.background.services StringKey string hello-world
for pair in BoolKey IntKey StringKey; do capture_preference_key test.background.services "$pair" "$TMP/$pair.json" || fail "capture failed for $pair"; done
put_value test.background.services BoolKey bool false
put_value test.background.services IntKey int 9
put_value test.background.services StringKey string changed
restore_preference_key test.background.services BoolKey "$TMP/BoolKey.json" || fail "bool restore failed"
restore_preference_key test.background.services IntKey "$TMP/IntKey.json" || fail "int restore failed"
restore_preference_key test.background.services StringKey "$TMP/StringKey.json" || fail "string restore failed"
assert_eq "$(get_value test.background.services BoolKey)" 1 "bool mismatch"
assert_eq "$(get_value test.background.services IntKey)" 42 "int mismatch"
assert_eq "$(get_value test.background.services StringKey)" hello-world "string mismatch"
background_service_supported_pair com.apple.securityd Enabled && fail "protected/unknown domain accepted"

# Failed App Store write must self-rollback earlier Software Update writes.
rm -rf "$STATE/settings"; mkdir -p "$STATE/settings"
put_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled bool true
put_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload bool true
put_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates bool true
put_value com.apple.commerce AutoUpdate bool true
put_value com.apple.commerce AutoUpdateRestartRequired bool true
export FAKE_DEFAULTS_FAIL_KEY=AutoUpdate
set +e
"$ROOT/scripts/background_service_settings_apply.sh" --requesting-uid 501
status=$?
set -e
unset FAKE_DEFAULTS_FAIL_KEY
assert_eq "$status" 20 "failed apply did not report verified rollback"
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled)" 1 "rollback missed AutomaticCheckEnabled"
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload)" 1 "rollback missed AutomaticDownload"
assert_eq "$(get_value /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates)" 1 "rollback missed install key"
grep -F '"state":"rolledBack"' "$STATE/settings/settings-status.json" >/dev/null || fail "rollback status missing"

for script in \
    "$ROOT/scripts/lib/background_service_settings_common.sh" \
    "$ROOT/scripts/background_service_settings_apply.sh" \
    "$ROOT/scripts/background_service_settings_restore.sh" \
    "$ROOT/scripts/background_service_settings_status.sh"; do
    /bin/sh -n "$script" || fail "shell syntax: $script"
done

printf 'PASS: Background service settings\n'
