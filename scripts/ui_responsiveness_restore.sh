#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib/foreground_session_common.sh"

dry_run=0
for argument in "$@"; do
    case $argument in
        --dry-run) dry_run=1 ;;
        --yes) : ;;
        *) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
    esac
done

runtime_dir=$(cp_runtime_dir)
logs_dir=$(cp_logs_dir)
state_file="$runtime_dir/ui_preferences.tsv"
log_file="$logs_dir/restore.log"

if [ ! -r "$state_file" ]; then
    printf 'No UI responsiveness state exists. Nothing to restore.\n'
    exit 0
fi

if [ "$dry_run" -eq 1 ]; then
    awk -F '\t' '
        NR == 1 { next }
        $8 != "restored" {
            if ($3 == "0") print "Would delete previously absent preference: " $1 " " $2
            else print "Would restore " $1 " " $2 " as " $4 "=" $5
        }
    ' "$state_file"
    exit 0
fi

if ! cp_prepare_storage; then
    printf 'Unable to verify Foreground Session storage. UI restore was not attempted.\n' >&2
    exit 1
fi

failure_flag="$runtime_dir/.ui_restore_failed.$$"
rm -f "$failure_flag"
tab=$(printf '\t')
awk -F '\t' 'NR > 1 && $8 != "restored" { print $1 "\t" $2 }' "$state_file" |
while IFS="$tab" read -r domain key; do
    row=$(awk -F '\t' -v domain="$domain" -v key="$key" 'NR > 1 && $1 == domain && $2 == key { print; exit }' "$state_file")
    [ -n "$row" ] || continue
    previous_exists=$(printf '%s\n' "$row" | awk -F '\t' '{print $3}')
    previous_type=$(printf '%s\n' "$row" | awk -F '\t' '{print $4}')
    previous_value=$(printf '%s\n' "$row" | awk -F '\t' '{print $5}')

    restored=0
    if [ "$previous_exists" = "0" ] || [ "$previous_type" = "absent" ]; then
        if $CP_DEFAULTS delete "$domain" "$key" >/dev/null 2>&1; then restored=1; else
            # `defaults delete` reports failure when already absent; verify absence.
            if ! $CP_DEFAULTS read "$domain" "$key" >/dev/null 2>&1; then restored=1; fi
        fi
    else
        case $previous_type in
            bool) flag=-bool ;;
            int) flag=-int ;;
            float) flag=-float ;;
            string) flag=-string ;;
            *) flag= ;;
        esac
        if [ -n "$flag" ] && $CP_DEFAULTS write "$domain" "$key" "$flag" "$previous_value" >/dev/null 2>&1; then
            restored=1
        fi
    fi

    if [ "$restored" -eq 1 ]; then
        status=restored
        cp_log "$log_file" "domain=$domain key=$key restored=1"
    else
        status=failed
        : > "$failure_flag"
        cp_log "$log_file" "domain=$domain key=$key restore_failed=1"
    fi

    update_file="$state_file.update.$$"
    awk -F '\t' -v OFS='\t' -v domain="$domain" -v key="$key" -v status="$status" '
        NR == 1 { print; next }
        $1 == domain && $2 == key { $8=status }
        { print }
    ' "$state_file" > "$update_file" && mv "$update_file" "$state_file"
done

if [ -e "$failure_flag" ]; then
    rm -f "$failure_flag"
    printf 'UI responsiveness restore is incomplete. Failed state was preserved for retry.\n' >&2
    exit 1
fi

pending=$(awk -F '\t' 'NR > 1 && $8 != "restored" { count++ } END { print count+0 }' "$state_file")
if [ "$pending" -gt 0 ]; then
    printf 'UI responsiveness restore remains pending for %s preference(s).\n' "$pending" >&2
    exit 1
fi

restored=$(awk -F '\t' 'NR > 1 && $8 == "restored" { count++ } END { print count+0 }' "$state_file")
printf 'Restored %s UI responsiveness preference(s) to their exact recorded state.\n' "$restored"
