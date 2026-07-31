#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib/foreground_session_common.sh"

dry_run=0
confirmed=0
for argument in "$@"; do
    case $argument in
        --dry-run) dry_run=1 ;;
        --yes) confirmed=1 ;;
        *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
    esac
done

runtime_dir=$(cp_runtime_dir)
logs_dir=$(cp_logs_dir)
apps_file="$runtime_dir/applications.tsv"
log_file="$logs_dir/restore.log"

if [ ! -r "$apps_file" ]; then
    printf 'No Foreground Session application state exists. Nothing to restore.\n'
    exit 0
fi

if [ "$dry_run" -eq 1 ]; then
    awk -F '\t' '
        NR == 1 { next }
        $3 == "1" && $4 == "1" && $5 == "1" && $6 == "1" && $7 != "success" && $7 != "already_running" {
            print "Would relaunch if not already running: " $1
        }
    ' "$apps_file"
    exit 0
fi

if [ "$confirmed" -ne 1 ]; then
    printf 'Refusing to relaunch applications without --yes.\n' >&2
    exit 2
fi
if ! cp_prepare_storage; then
    printf 'Unable to verify Foreground Session storage. Restore was not attempted.\n' >&2
    exit 1
fi

failure_flag="$runtime_dir/.relaunch_failed.$$"
rm -f "$failure_flag"
tab=$(printf '\t')
awk -F '\t' 'NR > 1 && $3 == "1" && $4 == "1" && $5 == "1" && $6 == "1" && $7 != "success" && $7 != "already_running" { print $1 }' "$apps_file" |
while IFS= read -r bundle_id; do
    cp_validate_bundle_id "$bundle_id" || continue
    if cp_is_excluded_bundle_id "$bundle_id"; then continue; fi

    if cp_application_is_running "$bundle_id"; then
        relaunch_result=already_running
        should_relaunch=0
        cp_log "$log_file" "bundle=$bundle_id relaunch=already_running"
    elif "$CP_OPEN" -b "$bundle_id" >/dev/null 2>&1; then
        # Give LaunchServices a bounded opportunity to report the app as running.
        elapsed=0
        while ! cp_application_is_running "$bundle_id" && [ "$elapsed" -lt 10 ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        if cp_application_is_running "$bundle_id"; then
            relaunch_result=success
            should_relaunch=0
            cp_log "$log_file" "bundle=$bundle_id relaunch=success"
        else
            relaunch_result=failed
            should_relaunch=1
            : > "$failure_flag"
            cp_log "$log_file" "bundle=$bundle_id relaunch=failed_not_running"
        fi
    else
        relaunch_result=failed
        should_relaunch=1
        : > "$failure_flag"
        cp_log "$log_file" "bundle=$bundle_id relaunch=failed_open"
    fi

    update_file="$apps_file.update.$$"
    awk -F '\t' -v OFS='\t' -v id="$bundle_id" -v relaunch="$should_relaunch" -v result="$relaunch_result" '
        NR == 1 { print; next }
        $1 == id { $6=relaunch; $7=result }
        { print }
    ' "$apps_file" > "$update_file" && mv "$update_file" "$apps_file"
done

if [ -e "$failure_flag" ]; then
    rm -f "$failure_flag"
    cp_log "$log_file" 'restore_incomplete=1'
    printf 'Application restore is incomplete. Failed relaunch state was preserved for retry.\n' >&2
    exit 1
fi

# Re-check durable state rather than relying on shell-loop variables.
pending=$(awk -F '\t' 'NR > 1 && $6 == "1" && $7 != "success" && $7 != "already_running" { count++ } END { print count+0 }' "$apps_file")
if [ "$pending" -gt 0 ]; then
    printf 'Application restore remains pending for %s application(s).\n' "$pending" >&2
    exit 1
fi

cp_write_session_active 0 || { printf 'Applications restored, but session state could not be marked inactive.\n' >&2; exit 1; }
restored=$(awk -F '\t' 'NR > 1 && ($7 == "success" || $7 == "already_running") { count++ } END { print count+0 }' "$apps_file")
cp_log "$log_file" "restore_complete=1 applications=$restored"
printf 'Foreground Session application restore complete: %s application(s) handled.\n' "$restored"
