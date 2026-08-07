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

preferences_file=$(cp_preferences_file)
selected_file=${TMPDIR:-/tmp}/catalina-performance-selected.$$
initial_file=${TMPDIR:-/tmp}/catalina-performance-apps-initial.$$
trap 'rm -f "$selected_file" "$initial_file"' EXIT HUP INT TERM

cp_selected_bundle_ids > "$selected_file"
selected_count=$(awk 'NF { count++ } END { print count+0 }' "$selected_file")
feature_enabled=$(cp_read_boolean_preference FOREGROUND_SESSION_ENABLED 0)

if [ "$feature_enabled" != "1" ]; then
    printf 'Foreground Performance Session is disabled. No applications were changed.\n'
    exit 0
fi
if [ "$selected_count" -eq 0 ]; then
    printf 'Foreground Performance Session is enabled, but no eligible applications are selected.\n'
    exit 0
fi

printf 'Foreground Performance Session apply%s\n' "$( [ "$dry_run" -eq 1 ] && printf ' dry run' || true )"
printf 'Preferences: %s\n' "$preferences_file"
printf 'Selected eligible applications: %s\n' "$selected_count"

if [ "$dry_run" -eq 1 ]; then
    while IFS= read -r bundle_id; do
        if cp_application_is_running "$bundle_id"; then
            printf 'Would request a normal quit: %s\n' "$bundle_id"
        else
            printf 'Would skip because it is not running: %s\n' "$bundle_id"
        fi
    done < "$selected_file"
    exit 0
fi

if [ "$confirmed" -ne 1 ]; then
    printf 'Refusing to change applications without --yes.\n' >&2
    exit 2
fi

if ! cp_prepare_storage; then
    printf 'Unable to create and verify Foreground Session storage. No quit requests were sent.\n' >&2
    exit 1
fi
if cp_session_is_active; then
    printf 'A Foreground Performance Session is already active. Restore it before applying another session.\n' >&2
    exit 1
fi

runtime_dir=$(cp_runtime_dir)
logs_dir=$(cp_logs_dir)
apps_file="$runtime_dir/applications.tsv"
log_file="$logs_dir/apply.log"
session_id=$(date '+%Y%m%d%H%M%S').$$

printf 'bundle_identifier\tdisplay_name\twas_running\tquit_requested\tconfirmed_closed\tshould_relaunch\trelaunch_result\n' > "$initial_file" || exit 1
while IFS= read -r bundle_id; do
    display_name=$(cp_application_display_name "$bundle_id")
    if cp_application_is_running "$bundle_id"; then was_running=1; else was_running=0; fi
    printf '%s\t%s\t%s\t0\t0\t0\tnot_requested\n' "$bundle_id" "$display_name" "$was_running" >> "$initial_file" || exit 1
done < "$selected_file"

# Write and read back all runtime state before the first quit request.
cp_write_session_active 1 "$session_id" || { printf 'Unable to write session state. No quit requests were sent.\n' >&2; exit 1; }
cp "$initial_file" "$apps_file.tmp.$$" || { cp_write_session_active 0 "$session_id"; exit 1; }
cat "$apps_file.tmp.$$" >/dev/null 2>&1 || { rm -f "$apps_file.tmp.$$"; cp_write_session_active 0 "$session_id"; exit 1; }
mv "$apps_file.tmp.$$" "$apps_file" || { cp_write_session_active 0 "$session_id"; exit 1; }
cp_log "$log_file" "session=$session_id state_written selected=$selected_count"

timeout=${CATALINA_PERFORMANCE_FOREGROUND_QUIT_TIMEOUT:-10}
case $timeout in ''|*[!0-9]*) timeout=10 ;; esac
[ "$timeout" -ge 1 ] 2>/dev/null || timeout=1
[ "$timeout" -le 60 ] 2>/dev/null || timeout=60

tab=$(printf '\t')
tail -n +2 "$apps_file" | while IFS="$tab" read -r bundle_id display_name was_running quit_requested confirmed_closed should_relaunch relaunch_result; do
    [ "$was_running" = "1" ] || continue

    if cp_request_graceful_quit "$bundle_id"; then
        quit_requested=1
        cp_log "$log_file" "bundle=$bundle_id graceful_quit_requested=1"
    else
        cp_log "$log_file" "bundle=$bundle_id graceful_quit_request_failed=1"
    fi

    if [ "$quit_requested" = "1" ]; then
        elapsed=0
        while cp_application_is_running "$bundle_id" && [ "$elapsed" -lt "$timeout" ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        if cp_application_is_running "$bundle_id"; then
            cp_log "$log_file" "bundle=$bundle_id confirmed_closed=0 timeout=$timeout"
        else
            confirmed_closed=1
            should_relaunch=1
            relaunch_result=pending
            cp_log "$log_file" "bundle=$bundle_id confirmed_closed=1"
        fi
    fi

    update_file="$apps_file.update.$$"
    awk -F '\t' -v OFS='\t' -v id="$bundle_id" -v requested="$quit_requested" -v closed="$confirmed_closed" -v relaunch="$should_relaunch" -v result="$relaunch_result" '
        NR == 1 { print; next }
        $1 == id { $4=requested; $5=closed; $6=relaunch; $7=result }
        { print }
    ' "$apps_file" > "$update_file" && mv "$update_file" "$apps_file"
done

# The while loop may run in a subshell, so summarize from durable state.
closed_count=$(awk -F '\t' 'NR > 1 && $5 == "1" { count++ } END { print count+0 }' "$apps_file")
skipped_count=$(awk -F '\t' 'NR > 1 && ($3 != "1" || $5 != "1") { count++ } END { print count+0 }' "$apps_file")
printf 'Apply complete: %s confirmed closed; %s skipped, refused, or still running.\n' "$closed_count" "$skipped_count"
printf 'Only confirmed-closed applications are eligible for relaunch.\n'
