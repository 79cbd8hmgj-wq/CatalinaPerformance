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
if [ -f "$BACKGROUND_SERVICE_PUBLIC_STATUS_FILE" ] && [ ! -L "$BACKGROUND_SERVICE_PUBLIC_STATUS_FILE" ]; then
    cat "$BACKGROUND_SERVICE_PUBLIC_STATUS_FILE"
    exit 0
fi
write_settings_status notConfigured 'No settings status exists.' notConfigured notConfigured
cat "$BACKGROUND_SERVICE_PUBLIC_STATUS_FILE"
exit 10
