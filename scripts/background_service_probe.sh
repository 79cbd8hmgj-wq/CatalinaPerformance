#!/bin/sh
set -u

usage() {
    cat <<'EOF'
Usage: background_service_probe.sh --uid <requesting-uid> [--output <path>]

Collects read-only macOS Catalina service/process metadata and update preference
values needed to build a finite Background Service Suppression target catalog.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 2
}

REQUESTING_UID=
OUTPUT_PATH=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --uid)
            [ "$#" -ge 2 ] || fail "--uid requires a value"
            REQUESTING_UID=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || fail "--output requires a path"
            OUTPUT_PATH=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

case "$REQUESTING_UID" in
    ''|*[!0-9]*) fail "requesting UID must be a positive integer" ;;
esac
[ "$REQUESTING_UID" -gt 0 ] || fail "requesting UID must be nonzero"

SYSTEM_NAME=$(/usr/bin/uname -s 2>/dev/null || /bin/uname -s 2>/dev/null || printf 'unknown')
[ "$SYSTEM_NAME" = "Darwin" ] || fail "this read-only probe requires Darwin"

CURRENT_UID=$(/usr/bin/id -u 2>/dev/null || /bin/id -u 2>/dev/null || printf '0')
[ "$CURRENT_UID" = "$REQUESTING_UID" ] || fail "run the probe as the requesting user"

if [ -n "$OUTPUT_PATH" ]; then
    [ ! -L "$OUTPUT_PATH" ] || fail "output path must not be a symbolic link"
    OUTPUT_PARENT=$(dirname -- "$OUTPUT_PATH")
    [ -d "$OUTPUT_PARENT" ] || fail "output directory does not exist"
    umask 077
    : > "$OUTPUT_PATH" || fail "cannot create output file"
    chmod 600 "$OUTPUT_PATH" || fail "cannot secure output file"
    exec > "$OUTPUT_PATH"
else
    umask 077
fi

section() {
    printf '\n===== %s =====\n' "$1"
}

candidate_service_labels() {
    cat <<'EOF'
com.apple.SoftwareUpdateNotificationManager
com.apple.appstoreagent
com.apple.storedownloadd
com.apple.storeassetd
com.apple.photolibraryd
com.apple.cloudphotod
com.apple.photoanalysisd
com.apple.mediaanalysisd
com.apple.email.maild
com.apple.MailServiceAgent
com.apple.mdworker.mail
com.apple.imagent
com.apple.IMDPersistenceAgent
com.apple.imautomatichistorydeletionagent
com.apple.cmfsyncagent
com.apple.CallHistorySyncHelper
com.apple.telephonyutilities.callservicesd
com.apple.corespeechd
com.apple.siriknowledged
com.apple.DictationIM
com.apple.assistant_service
com.apple.speech.speechdatainstallerd
com.apple.bird
EOF
}

print_candidate_service_details() {
    candidate_service_labels | while IFS= read -r label; do
        [ -n "$label" ] || continue
        printf '\n--- SERVICE %s ---\n' "$label"
        /bin/launchctl print "gui/$REQUESTING_UID/$label" 2>&1 || printf 'NOT_LOADED: %s\n' "$label"
    done
}

print_candidate_launch_agent_plists() {
    labels=$(candidate_service_labels)
    for directory in /System/Library/LaunchAgents /Library/LaunchAgents; do
        [ -d "$directory" ] || continue
        for plist in "$directory"/*.plist; do
            [ -f "$plist" ] || continue
            plist_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null || printf '')
            [ -n "$plist_label" ] || continue
            printf '%s\n' "$labels" | /usr/bin/grep -F -x "$plist_label" >/dev/null 2>&1 || continue
            printf '\n--- LAUNCH AGENT %s ---\n' "$plist_label"
            printf 'path=%s\n' "$plist"
            /usr/bin/plutil -p "$plist" 2>&1 || printf 'UNREADABLE_PLIST: %s\n' "$plist"
        done
    done
}

print_application_identifier() {
    app_path=$1
    label=$2
    printf '\n--- APPLICATION %s ---\n' "$label"
    printf 'path=%s\n' "$app_path"
    if [ -d "$app_path" ]; then
        identifier=$(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleIdentifier 2>/dev/null || printf '')
        if [ -n "$identifier" ]; then
            printf 'bundle_identifier=%s\n' "$identifier"
        else
            printf 'BUNDLE_IDENTIFIER_UNAVAILABLE\n'
        fi
    else
        printf 'APPLICATION_NOT_FOUND\n'
    fi
}

section "PROBE METADATA"
printf 'schema=2\n'
printf 'requesting_uid=%s\n' "$REQUESTING_UID"
printf 'captured_at_utc=%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

section "MACOS VERSION"
/usr/bin/sw_vers 2>&1 || printf 'UNAVAILABLE: sw_vers\n'

section "KERNEL"
/usr/bin/uname -a 2>&1 || /bin/uname -a 2>&1 || printf 'UNAVAILABLE: uname\n'

section "HARDWARE MODEL"
/usr/sbin/sysctl -n hw.model 2>&1 || printf 'UNAVAILABLE: hw.model\n'

section "USER LAUNCH DOMAIN"
/bin/launchctl print "gui/$REQUESTING_UID" 2>&1 || printf 'UNAVAILABLE: launchctl print gui/%s\n' "$REQUESTING_UID"

section "PROCESS METADATA"
/bin/ps -ww -axo pid=,ppid=,uid=,lstart=,command= 2>&1 || printf 'UNAVAILABLE: process metadata\n'

section "CANDIDATE SERVICE DETAILS"
print_candidate_service_details

section "CANDIDATE LAUNCH AGENT PLISTS"
print_candidate_launch_agent_plists

section "ASSOCIATED APPLICATION IDENTIFIERS"
print_application_identifier "/System/Applications/Photos.app" "Photos"
print_application_identifier "/System/Applications/Mail.app" "Mail"
print_application_identifier "/System/Applications/Messages.app" "Messages"
print_application_identifier "/System/Applications/FaceTime.app" "FaceTime"
print_application_identifier "/System/Applications/App Store.app" "App Store"
print_application_identifier "/System/Applications/System Preferences.app" "System Preferences"
print_application_identifier "/System/Library/CoreServices/Siri.app" "Siri"

section "SOFTWARE UPDATE PREFERENCES"
if /usr/bin/defaults export /Library/Preferences/com.apple.SoftwareUpdate - 2>/dev/null; then
    :
else
    printf 'MISSING_OR_UNREADABLE: /Library/Preferences/com.apple.SoftwareUpdate\n'
fi

section "APP STORE COMMERCE PREFERENCES"
if /usr/bin/defaults export com.apple.commerce - 2>/dev/null; then
    :
else
    printf 'MISSING_OR_UNREADABLE: com.apple.commerce\n'
fi

section "END"
printf 'Read-only probe complete. No settings or services were modified.\n'
