#!/bin/sh

prepare_background_service_wrapper_environment() {
    state_root=${CATALINA_PERFORMANCE_STATE_DIR:-"$SCRIPT_DIR/../.catalina_performance_state"}
    CATALINA_PERFORMANCE_BACKGROUND_SERVICE_STATE_DIR=$state_root/background_service_suppression
    if [ -z "${CATALINA_PERFORMANCE_BACKGROUND_SERVICE_PUBLIC_STATUS_DIR:-}" ]; then
        CATALINA_PERFORMANCE_BACKGROUND_SERVICE_PUBLIC_STATUS_DIR=$state_root/../background_service_status
    fi
    export CATALINA_PERFORMANCE_BACKGROUND_SERVICE_STATE_DIR
    export CATALINA_PERFORMANCE_BACKGROUND_SERVICE_PUBLIC_STATUS_DIR
}

apply_background_service_settings() {
    /bin/sh "$SCRIPT_DIR/background_service_settings_apply.sh" --requesting-uid "$REQUESTING_UID"
    status=$?
    case "$status" in
        0|10) return 0 ;;
        20)
            printf 'Background update settings could not be paused; verified self-rollback completed. Continuing core Performance Mode.\n' >&2
            return 10
            ;;
        21)
            printf 'Background update settings have unresolved partial state; Performance Mode will not continue.\n' >&2
            return 21
            ;;
        *) return "$status" ;;
    esac
}

restore_background_service_settings() {
    /bin/sh "$SCRIPT_DIR/background_service_settings_restore.sh" --requesting-uid "$REQUESTING_UID"
    status=$?
    case "$status" in
        0|10) return 0 ;;
        *) return "$status" ;;
    esac
}
