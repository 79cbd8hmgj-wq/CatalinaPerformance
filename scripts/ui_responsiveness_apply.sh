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

feature_enabled=$(cp_read_boolean_preference FOREGROUND_SESSION_ENABLED 0)
if [ "$feature_enabled" != "1" ]; then
    printf 'Foreground Performance Session is disabled. No UI preferences were changed.\n'
    exit 0
fi

finder=$(cp_read_boolean_preference DISABLE_FINDER_ANIMATIONS 1)
dock=$(cp_read_boolean_preference SHORTEN_DOCK_ANIMATIONS 1)
window=$(cp_read_boolean_preference DISABLE_WINDOW_ANIMATIONS 1)

preference_rows=${TMPDIR:-/tmp}/catalina-performance-ui-preferences.$$
trap 'rm -f "$preference_rows"' EXIT HUP INT TERM
: > "$preference_rows"
[ "$finder" = "1" ] && printf 'com.apple.finder\tDisableAllAnimations\tbool\ttrue\n' >> "$preference_rows"
if [ "$dock" = "1" ]; then
    printf 'com.apple.dock\tlaunchanim\tbool\tfalse\n' >> "$preference_rows"
    printf 'com.apple.dock\texpose-animation-duration\tfloat\t0.1\n' >> "$preference_rows"
fi
[ "$window" = "1" ] && printf 'NSGlobalDomain\tNSAutomaticWindowAnimationsEnabled\tbool\tfalse\n' >> "$preference_rows"

if [ ! -s "$preference_rows" ]; then
    printf 'No UI responsiveness options are enabled.\n'
    exit 0
fi

if [ "$dry_run" -eq 1 ]; then
    printf 'UI responsiveness dry run; no preferences were changed.\n'
    tab=$(printf '\t')
    while IFS="$tab" read -r domain key applied_type applied_value; do
        printf 'Would write %s %s as %s=%s\n' "$domain" "$key" "$applied_type" "$applied_value"
    done < "$preference_rows"
    exit 0
fi

if ! cp_prepare_storage; then
    printf 'Unable to create and verify Foreground Session storage. No UI preferences were changed.\n' >&2
    exit 1
fi

runtime_dir=$(cp_runtime_dir)
logs_dir=$(cp_logs_dir)
state_file="$runtime_dir/ui_preferences.tsv"
log_file="$logs_dir/apply.log"

if [ -r "$state_file" ] && awk -F '\t' 'NR > 1 && $8 != "restored" { pending=1 } END { exit(pending ? 0 : 1) }' "$state_file"; then
    printf 'UI responsiveness restore is still pending. Restore it before applying again.\n' >&2
    exit 1
fi

new_state="$state_file.new.$$"
printf 'domain\tkey\tprevious_exists\tprevious_type\tprevious_value\tapplied_type\tapplied_value\trestore_status\n' > "$new_state" || exit 1

type_name() {
    case $1 in
        *boolean*) printf 'bool\n' ;;
        *integer*) printf 'int\n' ;;
        *float*|*double*) printf 'float\n' ;;
        *string*) printf 'string\n' ;;
        *) printf 'unsupported\n' ;;
    esac
}

tab=$(printf '\t')
while IFS="$tab" read -r domain key applied_type applied_value; do
    previous_exists=0
    previous_type=absent
    previous_value=__CP_ABSENT__
    if previous_value_raw=$($CP_DEFAULTS read "$domain" "$key" 2>/dev/null); then
        previous_exists=1
        previous_type_raw=$($CP_DEFAULTS read-type "$domain" "$key" 2>/dev/null || true)
        previous_type=$(type_name "$previous_type_raw")
        if [ "$previous_type" = "unsupported" ]; then
            cp_log "$log_file" "domain=$domain key=$key skipped=unsupported_type raw=$(cp_sanitize_tsv_field "$previous_type_raw")"
            printf 'Skipping %s %s because its existing type cannot be restored safely.\n' "$domain" "$key" >&2
            continue
        fi
        previous_value=$(cp_sanitize_tsv_field "$previous_value_raw")
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tpending\n' "$domain" "$key" "$previous_exists" "$previous_type" "$previous_value" "$applied_type" "$applied_value" >> "$new_state" || exit 1
done < "$preference_rows"

# The complete pre-state must be durable and readable before the first write.
cat "$new_state" >/dev/null 2>&1 || { rm -f "$new_state"; exit 1; }
mv "$new_state" "$state_file" || exit 1

apply_failed=0
tail -n +2 "$state_file" | while IFS="$tab" read -r domain key previous_exists previous_type previous_value applied_type applied_value restore_status; do
    case $applied_type in
        bool) flag=-bool ;;
        int) flag=-int ;;
        float) flag=-float ;;
        string) flag=-string ;;
        *) : > "$runtime_dir/.ui_apply_failed.$$"; continue ;;
    esac
    if $CP_DEFAULTS write "$domain" "$key" "$flag" "$applied_value" >/dev/null 2>&1; then
        cp_log "$log_file" "domain=$domain key=$key applied_type=$applied_type applied_value=$applied_value"
    else
        : > "$runtime_dir/.ui_apply_failed.$$"
        cp_log "$log_file" "domain=$domain key=$key apply_failed=1"
        break
    fi
done

if [ -e "$runtime_dir/.ui_apply_failed.$$" ]; then
    rm -f "$runtime_dir/.ui_apply_failed.$$"
    printf 'A UI preference write failed. Attempting immediate rollback.\n' >&2
    if /bin/sh "$SCRIPT_DIR/ui_responsiveness_restore.sh" --yes; then
        printf 'UI preference rollback completed.\n' >&2
    else
        printf 'UI preference rollback is incomplete; state was preserved for retry.\n' >&2
    fi
    exit 1
fi

applied_count=$(awk 'NR > 1 { count++ } END { print count+0 }' "$state_file")
printf 'Applied %s reversible UI responsiveness preference(s).\n' "$applied_count"
printf 'Finder and Dock changes may take effect after those components naturally restart; this patch does not signal or forcibly restart them.\n'
