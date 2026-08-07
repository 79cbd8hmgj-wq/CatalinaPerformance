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
found=0
failed=0
for row in $KEYS; do
    old_ifs=$IFS; IFS='|'; set -- $row; IFS=$old_ifs
    snapshot=$BACKGROUND_SERVICE_SETTINGS_DIR/$3
    [ -f "$snapshot" ] || continue
    found=1
    if restore_preference_key "$1" "$2" "$snapshot"; then
        rm -f "$snapshot"
    else
        failed=1
    fi
done
if [ "$found" -eq 0 ]; then
    write_settings_status notConfigured 'No saved update-setting baseline exists.' notConfigured notConfigured
    exit 10
fi
if [ "$failed" -ne 0 ]; then
    write_settings_status restoreFailed 'One or more update settings could not be restored.' restoreFailed restoreFailed
    exit 21
fi
write_settings_status restored 'Update settings restored exactly.' restored restored
exit 0
