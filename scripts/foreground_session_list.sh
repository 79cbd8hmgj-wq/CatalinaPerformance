#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/foreground_session_common.sh
. "$SCRIPT_DIR/lib/foreground_session_common.sh"

raw_file=
cleanup() {
    if [ -n "$raw_file" ] && [ "${CATALINA_PERFORMANCE_RUNNING_APPS_FILE:-}" != "$raw_file" ]; then
        rm -f "$raw_file"
    fi
}
trap cleanup EXIT HUP INT TERM

if [ -n "${CATALINA_PERFORMANCE_RUNNING_APPS_FILE:-}" ]; then
    raw_file=$CATALINA_PERFORMANCE_RUNNING_APPS_FILE
    [ -r "$raw_file" ] || { printf 'Unable to read running-app fixture: %s\n' "$raw_file" >&2; exit 1; }
else
    raw_file=${TMPDIR:-/tmp}/catalina-performance-running-apps.$$
    if ! "$CP_OSASCRIPT" > "$raw_file" <<'APPLESCRIPT'
tell application "System Events"
    set outputText to ""
    repeat with processItem in (application processes whose background only is false)
        try
            set processName to name of processItem
            set processBundleID to bundle identifier of processItem
            if processBundleID is not missing value and processBundleID is not "" then
                set outputText to outputText & processName & tab & processBundleID & linefeed
            end if
        end try
    end repeat
    return outputText
end tell
APPLESCRIPT
    then
        printf 'Unable to query running GUI applications. System Events may require Automation permission.\n' >&2
        exit 1
    fi
fi

printf 'display_name\tbundle_identifier\trunning\n'
tab=$(printf '\t')
awk -F '\t' 'NF >= 2 { print $1 "\t" $2 }' "$raw_file" |
while IFS="$tab" read -r display_name bundle_id; do
    display_name=$(cp_sanitize_tsv_field "$display_name")
    bundle_id=$(cp_trim "$bundle_id")
    if cp_validate_bundle_id "$bundle_id" && ! cp_is_excluded_bundle_id "$bundle_id"; then
        printf '%s\t%s\t1\n' "$display_name" "$bundle_id"
    fi
done | LC_ALL=C sort -f -t "$(printf '\t')" -k1,1 -k2,2 | awk -F '\t' '!seen[$2]++'
