#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/lib/foreground_session_common.sh"

runtime_dir=$(cp_runtime_dir)
apps_file="$runtime_dir/applications.tsv"
ui_file="$runtime_dir/ui_preferences.tsv"

if cp_session_is_active; then session_active=1; else session_active=0; fi
if [ -r "$apps_file" ]; then
    awk -F '\t' -v active="$session_active" '
        BEGIN { selected=0; running=0; closed=0; skipped=0; pending=0; failed=0 }
        NR == 1 { next }
        NF >= 7 {
            selected++
            if ($3 == "1") running++
            if ($5 == "1") closed++
            if ($3 != "1" || $4 != "1" || $5 != "1") skipped++
            if ($6 == "1" && $7 != "success" && $7 != "already_running") pending++
            if ($7 == "failed") failed++
        }
        END {
            print "session_active=" active
            print "selected=" selected
            print "running_before=" running
            print "confirmed_closed=" closed
            print "skipped=" skipped
            print "pending_relaunch=" pending
            print "relaunch_failed=" failed
        }
    ' "$apps_file"
else
    printf 'session_active=%s\nselected=0\nrunning_before=0\nconfirmed_closed=0\nskipped=0\npending_relaunch=0\nrelaunch_failed=0\n' "$session_active"
fi

if [ -r "$ui_file" ]; then
    awk -F '\t' '
        NR == 1 { next }
        NF >= 8 { total++; if ($8 != "restored") pending++ }
        END { print "ui_preferences_recorded=" (total+0); print "ui_restore_pending=" (pending+0) }
    ' "$ui_file"
else
    printf 'ui_preferences_recorded=0\nui_restore_pending=0\n'
fi
