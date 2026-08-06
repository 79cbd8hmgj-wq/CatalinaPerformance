#!/bin/sh
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/lib/background_service_settings_common.sh"
REQUESTING_UID=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --requesting-uid) [ "$#" -ge 2 ] || exit 2; background_service_validate_uid "$2" || exit 2; shift 2 ;;
        --help|-h) printf 'Usage: %s --requesting-uid <uid>\n' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done
[ -n "$REQUESTING_UID" ] || exit 2
background_service_settings_init || exit 21
if [ "${BACKGROUND_SERVICE_TEST_MODE:-0}" != "1" ]; then
    [ "$(/usr/bin/id -u 2>/dev/null || /bin/id -u)" = 0 ] || exit 2
fi

KEYS='/Library/Preferences/com.apple.SoftwareUpdate|AutomaticCheckEnabled|software-update-AutomaticCheckEnabled.json
/Library/Preferences/com.apple.SoftwareUpdate|AutomaticDownload|software-update-AutomaticDownload.json
/Library/Preferences/com.apple.SoftwareUpdate|AutomaticallyInstallMacOSUpdates|software-update-AutomaticallyInstallMacOSUpdates.json
com.apple.commerce|AutoUpdate|app-store-AutoUpdate.json
com.apple.commerce|AutoUpdateRestartRequired|app-store-AutoUpdateRestartRequired.json'

for row in $KEYS; do
    old_ifs=$IFS; IFS='|'; set -- $row; IFS=$old_ifs
    snapshot=$BACKGROUND_SERVICE_SETTINGS_DIR/$3
    if [ -f "$snapshot" ]; then
        write_settings_status restoreFailed 'Existing unresolved settings baseline.' restoreFailed restoreFailed
        exit 21
    fi
done

captured=
changed=
apply_failed=0
for row in $KEYS; do
    old_ifs=$IFS; IFS='|'; set -- $row; IFS=$old_ifs
    domain=$1 key=$2 name=$3 snapshot=$BACKGROUND_SERVICE_SETTINGS_DIR/$3
    if ! capture_preference_key "$domain" "$key" "$snapshot"; then apply_failed=1; break; fi
    captured="$snapshot $captured"
    if ! write_boolean_preference "$domain" "$key" false; then
        apply_failed=1
        break
    fi
    changed="$domain|$key|$snapshot $changed"
    if ! verify_boolean_preference "$domain" "$key" false; then
        apply_failed=1
        break
    fi
done

if [ "$apply_failed" -ne 0 ]; then
    rollback_failed=0
    for item in $changed; do
        old_ifs=$IFS; IFS='|'; set -- $item; IFS=$old_ifs
        restore_preference_key "$1" "$2" "$3" || rollback_failed=1
    done
    if [ "$rollback_failed" -eq 0 ]; then
        for snapshot in $captured; do rm -f "$snapshot"; done
        write_settings_status rolledBack 'Apply failed; changed settings were restored.' rolledBack rolledBack
        exit 20
    fi
    write_settings_status restoreFailed 'Apply failed and rollback is incomplete.' restoreFailed restoreFailed
    exit 21
fi

write_settings_status paused 'Automatic update settings paused for this Performance Mode session.' paused paused
exit 0
