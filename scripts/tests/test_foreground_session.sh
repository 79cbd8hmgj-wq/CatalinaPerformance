#!/bin/sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
COMMON="$REPO_ROOT/scripts/lib/foreground_session_common.sh"
TEST_ROOT=${TMPDIR:-/tmp}/catalina-performance-tests.$$
FAILURES=0
TEST_FILTER=${1:-all}

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
assert_equal() {
    expected=$1 actual=$2 description=$3
    if [ "$expected" = "$actual" ]; then pass "$description"; else fail "$description (expected=[$expected] actual=[$actual])"; fi
}
assert_contains() {
    haystack=$1 needle=$2 description=$3
    case $haystack in *"$needle"*) pass "$description" ;; *) fail "$description (missing [$needle])" ;; esac
}
assert_not_contains() {
    haystack=$1 needle=$2 description=$3
    case $haystack in *"$needle"*) fail "$description (unexpected [$needle])" ;; *) pass "$description" ;; esac
}
assert_file_missing() { [ ! -e "$1" ] && pass "$2" || fail "$2"; }
assert_file_exists() { [ -e "$1" ] && pass "$2" || fail "$2"; }

cat > "$TEST_ROOT/bin/fake_osascript" <<'FAKE_OSA'
#!/bin/sh
set -u
expr=
while [ "$#" -gt 0 ]; do
    case $1 in
        -e) shift; expr=${1:-} ;;
    esac
    shift || true
done
state=${FAKE_RUNNING_FILE:?}
quit_log=${FAKE_QUIT_LOG:?}
refuse=${FAKE_REFUSE_FILE:-/dev/null}
names=${FAKE_NAMES_FILE:-/dev/null}
extract_id() { printf '%s\n' "$1" | sed -n 's/.*application id "\([A-Za-z0-9.-]*\)".*/\1/p'; }
id=$(extract_id "$expr")
case $expr in
    *' is running')
        awk -F '\t' -v id="$id" '$1 == id && $2 == "1" { found=1 } END { print(found ? "true" : "false") }' "$state"
        ;;
    'tell application id '*" to quit")
        printf '%s\n' "$id" >> "$quit_log"
        if grep -Fx "$id" "$refuse" >/dev/null 2>&1; then exit 1; fi
        tmp="$state.tmp.$$"
        awk -F '\t' -v OFS='\t' -v id="$id" '$1 == id { $2="0" } { print }' "$state" > "$tmp" && mv "$tmp" "$state"
        ;;
    'name of application id '*)
        name=$(awk -F '\t' -v id="$id" '$1 == id { print $2; exit }' "$names")
        [ -n "$name" ] && printf '%s\n' "$name" || printf '%s\n' "$id"
        ;;
    *)
        # Listing tests use a fixture and never reach this path.
        exit 1
        ;;
esac
FAKE_OSA

cat > "$TEST_ROOT/bin/fake_open" <<'FAKE_OPEN'
#!/bin/sh
set -u
[ "${1:-}" = "-b" ] || exit 2
id=${2:-}
printf '%s\n' "$id" >> "${FAKE_OPEN_LOG:?}"
if grep -Fx "$id" "${FAKE_OPEN_FAIL_FILE:-/dev/null}" >/dev/null 2>&1; then exit 1; fi
state=${FAKE_RUNNING_FILE:?}
tmp="$state.tmp.$$"
awk -F '\t' -v OFS='\t' -v id="$id" '
    BEGIN { found=0 }
    $1 == id { $2="1"; found=1 }
    { print }
    END { if (!found) print id, "1" }
' "$state" > "$tmp" && mv "$tmp" "$state"
FAKE_OPEN

cat > "$TEST_ROOT/bin/fake_defaults" <<'FAKE_DEFAULTS'
#!/bin/sh
set -u
store=${FAKE_DEFAULTS_STORE:?}
command=${1:-}
domain=${2:-}
key=${3:-}
lookup() { awk -F '\t' -v d="$domain" -v k="$key" '$1 == d && $2 == k { print; exit }' "$store"; }
case $command in
    read)
        row=$(lookup)
        [ -n "$row" ] || exit 1
        printf '%s\n' "$row" | awk -F '\t' '{ print $4 }'
        ;;
    read-type)
        row=$(lookup)
        [ -n "$row" ] || exit 1
        type=$(printf '%s\n' "$row" | awk -F '\t' '{ print $3 }')
        case $type in
            bool) printf 'Type is boolean\n' ;;
            int) printf 'Type is integer\n' ;;
            float) printf 'Type is float\n' ;;
            string) printf 'Type is string\n' ;;
            *) printf 'Type is %s\n' "$type" ;;
        esac
        ;;
    write)
        flag=${4:-}; value=${5:-}
        case $flag in -bool) type=bool ;; -int) type=int ;; -float) type=float ;; -string) type=string ;; *) exit 2 ;; esac
        if grep -Fqx "$domain${TAB:-	}$key" "${FAKE_DEFAULTS_FAIL_WRITES:-/dev/null}" 2>/dev/null; then exit 1; fi
        tmp="$store.tmp.$$"
        awk -F '\t' -v OFS='\t' -v d="$domain" -v k="$key" '$1 == d && $2 == k { next } { print }' "$store" > "$tmp"
        printf '%s\t%s\t%s\t%s\n' "$domain" "$key" "$type" "$value" >> "$tmp"
        mv "$tmp" "$store"
        ;;
    delete)
        row=$(lookup)
        [ -n "$row" ] || exit 1
        tmp="$store.tmp.$$"
        awk -F '\t' -v d="$domain" -v k="$key" '!($1 == d && $2 == k)' "$store" > "$tmp" && mv "$tmp" "$store"
        ;;
    *) exit 2 ;;
esac
FAKE_DEFAULTS
chmod +x "$TEST_ROOT/bin/fake_osascript" "$TEST_ROOT/bin/fake_open" "$TEST_ROOT/bin/fake_defaults"

reset_fixture() {
    rm -rf "$TEST_ROOT/session"
    mkdir -p "$TEST_ROOT/session"
    export CATALINA_PERFORMANCE_FOREGROUND_DIR="$TEST_ROOT/session"
    export CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE="$TEST_ROOT/session/preferences.env"
    export CATALINA_PERFORMANCE_OSASCRIPT_BIN="$TEST_ROOT/bin/fake_osascript"
    export CATALINA_PERFORMANCE_OPEN_BIN="$TEST_ROOT/bin/fake_open"
    export CATALINA_PERFORMANCE_DEFAULTS_BIN="$TEST_ROOT/bin/fake_defaults"
    export CATALINA_PERFORMANCE_FOREGROUND_QUIT_TIMEOUT=1
    export FAKE_RUNNING_FILE="$TEST_ROOT/session/running.tsv"
    export FAKE_QUIT_LOG="$TEST_ROOT/session/quit.log"
    export FAKE_REFUSE_FILE="$TEST_ROOT/session/refuse.txt"
    export FAKE_NAMES_FILE="$TEST_ROOT/session/names.tsv"
    export FAKE_OPEN_LOG="$TEST_ROOT/session/open.log"
    export FAKE_OPEN_FAIL_FILE="$TEST_ROOT/session/open_fail.txt"
    export FAKE_DEFAULTS_STORE="$TEST_ROOT/session/defaults.tsv"
    : > "$FAKE_RUNNING_FILE"
    : > "$FAKE_QUIT_LOG"
    : > "$FAKE_REFUSE_FILE"
    : > "$FAKE_NAMES_FILE"
    : > "$FAKE_OPEN_LOG"
    : > "$FAKE_OPEN_FAIL_FILE"
    : > "$FAKE_DEFAULTS_STORE"
}

run_common_tests() {
    reset_fixture
    # shellcheck source=/dev/null
    . "$COMMON"
    assert_equal 1 "$(cp_validate_bundle_id org.mozilla.firefox && printf 1 || printf 0)" 'valid bundle ID'
    assert_equal 0 "$(cp_validate_bundle_id 'bad id;rm -rf /' && printf 1 || printf 0)" 'reject unsafe bundle ID'
    assert_equal 0 "$(cp_validate_bundle_id '.hidden' && printf 1 || printf 0)" 'reject leading dot'
    assert_equal 0 "$(cp_validate_bundle_id 'bad..id' && printf 1 || printf 0)" 'reject double dot'
    assert_equal 1 "$(cp_is_excluded_bundle_id com.apple.Terminal && printf 1 || printf 0)" 'exclude Terminal'
    assert_equal 1 "$(cp_is_excluded_bundle_id com.googlecode.iterm2 && printf 1 || printf 0)" 'exclude iTerm2'
    assert_equal 0 "$(cp_is_excluded_bundle_id org.mozilla.firefox && printf 1 || printf 0)" 'allow Firefox'
    cat > "$CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE" <<'PREFS'
FOREGROUND_SESSION_ENABLED=1
SELECTED_BUNDLE_ID= org.mozilla.firefox
SELECTED_BUNDLE_ID=com.apple.Terminal
SELECTED_BUNDLE_ID=org.mozilla.firefox
SELECTED_BUNDLE_ID= bad id
UNKNOWN_KEY=org.example.ignore
SELECTED_BUNDLE_ID=com.apple.TextEdit
PREFS
    selected=$(cp_selected_bundle_ids)
    assert_equal 'com.apple.TextEdit
org.mozilla.firefox' "$selected" 'parse sorted unique safe selections'
    assert_equal 1 "$(cp_read_boolean_preference FOREGROUND_SESSION_ENABLED 0)" 'read recognized boolean'
    assert_equal 1 "$(cp_prepare_storage && printf 1 || printf 0)" 'prepare storage round trip'
}

run_list_tests() {
    reset_fixture
    apps_fixture="$TEST_ROOT/session/apps.tsv"
    printf 'TextEdit\tcom.apple.TextEdit\nTerminal\tcom.apple.Terminal\nFirefox\torg.mozilla.firefox\nMissing ID\t\nCatalinaPerformance\tlocal.CatalinaPerformance\nFirefox Duplicate\torg.mozilla.firefox\n' > "$apps_fixture"
    output=$(CATALINA_PERFORMANCE_RUNNING_APPS_FILE="$apps_fixture" /bin/sh "$REPO_ROOT/scripts/foreground_session_list.sh")
    assert_contains "$output" 'TextEdit' 'list includes TextEdit'
    assert_contains "$output" 'org.mozilla.firefox' 'list includes Firefox'
    assert_not_contains "$output" 'com.apple.Terminal' 'list excludes Terminal'
    assert_not_contains "$output" 'local.CatalinaPerformance' 'list excludes CatalinaPerformance'
    firefox_count=$(printf '%s\n' "$output" | grep -c 'org.mozilla.firefox' || true)
    assert_equal 1 "$firefox_count" 'list deduplicates bundle IDs'
}

write_preferences() {
    cat > "$CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE" <<'PREFS'
FOREGROUND_SESSION_ENABLED=1
DISABLE_FINDER_ANIMATIONS=1
SHORTEN_DOCK_ANIMATIONS=1
DISABLE_WINDOW_ANIMATIONS=1
SELECTED_BUNDLE_ID=com.apple.TextEdit
SELECTED_BUNDLE_ID=org.mozilla.firefox
SELECTED_BUNDLE_ID=com.apple.Terminal
PREFS
}

run_apply_restore_tests() {
    reset_fixture
    write_preferences
    printf 'com.apple.TextEdit\t1\norg.mozilla.firefox\t1\n' > "$FAKE_RUNNING_FILE"
    printf 'com.apple.TextEdit\tTextEdit\norg.mozilla.firefox\tFirefox\n' > "$FAKE_NAMES_FILE"
    printf 'org.mozilla.firefox\n' > "$FAKE_REFUSE_FILE"

    dry_output=$(/bin/sh "$REPO_ROOT/scripts/foreground_session_apply.sh" --dry-run)
    assert_contains "$dry_output" 'Would request a normal quit: com.apple.TextEdit' 'dry run reports TextEdit'
    assert_file_missing "$CATALINA_PERFORMANCE_FOREGROUND_DIR/runtime/session.env" 'dry run creates no active state'
    assert_equal '' "$(cat "$FAKE_QUIT_LOG")" 'dry run sends no quit request'

    apply_output=$(/bin/sh "$REPO_ROOT/scripts/foreground_session_apply.sh" --yes)
    assert_contains "$apply_output" '1 confirmed closed' 'apply confirms one closure'
    assert_equal 'com.apple.TextEdit
org.mozilla.firefox' "$(cat "$FAKE_QUIT_LOG")" 'only eligible selected apps receive quit requests'
    apps_state=$(cat "$CATALINA_PERFORMANCE_FOREGROUND_DIR/runtime/applications.tsv")
    assert_contains "$apps_state" 'com.apple.TextEdit' 'state includes TextEdit'
    textedit_closed=$(awk -F '\t' '$1 == "com.apple.TextEdit" { print $5 }' "$CATALINA_PERFORMANCE_FOREGROUND_DIR/runtime/applications.tsv")
    firefox_closed=$(awk -F '\t' '$1 == "org.mozilla.firefox" { print $5 }' "$CATALINA_PERFORMANCE_FOREGROUND_DIR/runtime/applications.tsv")
    assert_equal 1 "$textedit_closed" 'confirmed exit recorded'
    assert_equal 0 "$firefox_closed" 'refused quit is not marked closed'

    restore_dry=$(/bin/sh "$REPO_ROOT/scripts/foreground_session_restore.sh" --dry-run)
    assert_contains "$restore_dry" 'com.apple.TextEdit' 'restore dry run lists only confirmed-closed app'
    assert_not_contains "$restore_dry" 'org.mozilla.firefox' 'restore dry run excludes refused app'

    restore_output=$(/bin/sh "$REPO_ROOT/scripts/foreground_session_restore.sh" --yes)
    assert_contains "$restore_output" 'restore complete' 'restore completes'
    assert_equal 'com.apple.TextEdit' "$(cat "$FAKE_OPEN_LOG")" 'restore relaunches only confirmed-closed app'
    active=$(/bin/sh "$REPO_ROOT/scripts/foreground_session_state.sh" | awk -F= '$1 == "session_active" { print $2 }')
    assert_equal 0 "$active" 'restore marks session inactive'
}

run_state_tests() {
    reset_fixture
    no_state=$(/bin/sh "$REPO_ROOT/scripts/foreground_session_state.sh")
    assert_contains "$no_state" 'session_active=0' 'state reports inactive without files'
    mkdir -p "$CATALINA_PERFORMANCE_FOREGROUND_DIR/runtime"
    cat > "$CATALINA_PERFORMANCE_FOREGROUND_DIR/runtime/session.env" <<'STATE'
SESSION_ACTIVE=1
STATE
    printf 'bundle_identifier\tdisplay_name\twas_running\tquit_requested\tconfirmed_closed\tshould_relaunch\trelaunch_result\ncom.apple.TextEdit\tTextEdit\t1\t1\t1\t1\tpending\norg.mozilla.firefox\tFirefox\t1\t1\t0\t0\tnot_requested\n' > "$CATALINA_PERFORMANCE_FOREGROUND_DIR/runtime/applications.tsv"
    state=$(/bin/sh "$REPO_ROOT/scripts/foreground_session_state.sh")
    assert_contains "$state" 'confirmed_closed=1' 'state counts confirmed closures'
    assert_contains "$state" 'pending_relaunch=1' 'state counts pending relaunches'
    assert_contains "$state" 'skipped=1' 'state counts skipped apps'
}

run_ui_tests() {
    reset_fixture
    write_preferences
    printf 'com.apple.finder\tDisableAllAnimations\tbool\tfalse\ncom.apple.dock\tlaunchanim\tbool\ttrue\ncom.apple.dock\texpose-animation-duration\tfloat\t0.35\nNSGlobalDomain\tNSAutomaticWindowAnimationsEnabled\tbool\ttrue\n' > "$FAKE_DEFAULTS_STORE"
    before=$(cat "$FAKE_DEFAULTS_STORE")
    dry=$(/bin/sh "$REPO_ROOT/scripts/ui_responsiveness_apply.sh" --legacy-test --dry-run)
    assert_contains "$dry" 'no preferences were changed' 'UI dry run reports no changes'
    assert_equal "$before" "$(cat "$FAKE_DEFAULTS_STORE")" 'UI dry run leaves defaults unchanged'

    applied=$(/bin/sh "$REPO_ROOT/scripts/ui_responsiveness_apply.sh" --legacy-test --yes)
    assert_contains "$applied" 'Applied 4 legacy reversible' 'UI apply changes four known preferences'
    finder_value=$(awk -F '\t' '$1 == "com.apple.finder" && $2 == "DisableAllAnimations" { print $4 }' "$FAKE_DEFAULTS_STORE")
    dock_duration=$(awk -F '\t' '$1 == "com.apple.dock" && $2 == "expose-animation-duration" { print $4 }' "$FAKE_DEFAULTS_STORE")
    assert_equal true "$finder_value" 'UI apply disables Finder animations'
    assert_equal 0.1 "$dock_duration" 'UI apply shortens Dock duration'

    restored=$(/bin/sh "$REPO_ROOT/scripts/ui_responsiveness_restore.sh" --yes)
    assert_contains "$restored" 'Restored 4' 'UI restore completes'
    # Compare normalized order because fake defaults rewrites append keys.
    assert_equal "$(printf '%s\n' "$before" | LC_ALL=C sort)" "$(LC_ALL=C sort "$FAKE_DEFAULTS_STORE")" 'UI restore reproduces exact prior scalar values'

    # Prior absence must be restored as absence.
    reset_fixture
    write_preferences
    : > "$FAKE_DEFAULTS_STORE"
    /bin/sh "$REPO_ROOT/scripts/ui_responsiveness_apply.sh" --legacy-test --yes >/dev/null
    /bin/sh "$REPO_ROOT/scripts/ui_responsiveness_restore.sh" --yes >/dev/null
    assert_equal '' "$(cat "$FAKE_DEFAULTS_STORE")" 'UI restore deletes keys that were previously absent'
}


run_failure_path_tests() {
    reset_fixture
    write_preferences
    printf 'com.apple.TextEdit\t1\n' > "$FAKE_RUNNING_FILE"
    printf 'com.apple.TextEdit\tTextEdit\n' > "$FAKE_NAMES_FILE"

    blocker="$TEST_ROOT/session/storage-blocker"
    : > "$blocker"
    export CATALINA_PERFORMANCE_FOREGROUND_DIR="$blocker/child"
    set +e
    /bin/sh "$REPO_ROOT/scripts/foreground_session_apply.sh" --yes > "$TEST_ROOT/storage-failure.out" 2>&1
    storage_status=$?
    set -e
    assert_equal 1 "$storage_status" 'unwritable storage fails apply'
    assert_equal '' "$(cat "$FAKE_QUIT_LOG")" 'storage failure occurs before quit request'

    reset_fixture
    write_preferences
    printf 'com.apple.TextEdit\t1\n' > "$FAKE_RUNNING_FILE"
    printf 'com.apple.TextEdit\tTextEdit\n' > "$FAKE_NAMES_FILE"
    /bin/sh "$REPO_ROOT/scripts/foreground_session_apply.sh" --yes >/dev/null
    printf 'com.apple.TextEdit\n' > "$FAKE_OPEN_FAIL_FILE"
    set +e
    /bin/sh "$REPO_ROOT/scripts/foreground_session_restore.sh" --yes > "$TEST_ROOT/relaunch-failure.out" 2>&1
    restore_status=$?
    set -e
    assert_equal 1 "$restore_status" 'failed relaunch returns nonzero'
    active=$(/bin/sh "$REPO_ROOT/scripts/foreground_session_state.sh" | awk -F= '$1 == "session_active" { print $2 }')
    assert_equal 1 "$active" 'failed relaunch preserves active session state'
    relaunch_result=$(awk -F '\t' '$1 == "com.apple.TextEdit" { print $7 }' "$CATALINA_PERFORMANCE_FOREGROUND_DIR/runtime/applications.tsv")
    assert_equal failed "$relaunch_result" 'failed relaunch is recorded for retry'
    : > "$FAKE_OPEN_FAIL_FILE"
    /bin/sh "$REPO_ROOT/scripts/foreground_session_restore.sh" --yes >/dev/null
    active=$(/bin/sh "$REPO_ROOT/scripts/foreground_session_state.sh" | awk -F= '$1 == "session_active" { print $2 }')
    assert_equal 0 "$active" 'successful retry completes preserved restore state'
}

run_ui_edge_tests() {
    reset_fixture
    cat > "$CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE" <<'PREFS'
FOREGROUND_SESSION_ENABLED=0
DISABLE_FINDER_ANIMATIONS=1
SHORTEN_DOCK_ANIMATIONS=1
DISABLE_WINDOW_ANIMATIONS=1
PREFS
    printf 'com.apple.finder\tDisableAllAnimations\tbool\tfalse\n' > "$FAKE_DEFAULTS_STORE"
    before=$(cat "$FAKE_DEFAULTS_STORE")
    disabled_output=$(/bin/sh "$REPO_ROOT/scripts/ui_responsiveness_apply.sh" --legacy-test --yes)
    assert_contains "$disabled_output" 'disabled' 'disabled feature skips UI mutation'
    assert_equal "$before" "$(cat "$FAKE_DEFAULTS_STORE")" 'disabled feature preserves defaults'
    assert_file_missing "$CATALINA_PERFORMANCE_FOREGROUND_DIR/runtime/ui_preferences.tsv" 'disabled feature writes no UI runtime state'

    reset_fixture
    write_preferences
    printf 'com.apple.finder\tDisableAllAnimations\tint\t7\ncom.apple.dock\tlaunchanim\tstring\tlegacy\ncom.apple.dock\texpose-animation-duration\tint\t4\nNSGlobalDomain\tNSAutomaticWindowAnimationsEnabled\tstring\tlegacy-window\n' > "$FAKE_DEFAULTS_STORE"
    before=$(LC_ALL=C sort "$FAKE_DEFAULTS_STORE")
    /bin/sh "$REPO_ROOT/scripts/ui_responsiveness_apply.sh" --legacy-test --yes >/dev/null
    /bin/sh "$REPO_ROOT/scripts/ui_responsiveness_restore.sh" --yes >/dev/null
    assert_equal "$before" "$(LC_ALL=C sort "$FAKE_DEFAULTS_STORE")" 'UI restore preserves prior int and string scalar types'

    reset_fixture
    cat > "$CATALINA_PERFORMANCE_FOREGROUND_PREFERENCES_FILE" <<'PREFS'
FOREGROUND_SESSION_ENABLED=1
DISABLE_FINDER_ANIMATIONS=1
SHORTEN_DOCK_ANIMATIONS=0
DISABLE_WINDOW_ANIMATIONS=0
PREFS
    printf 'com.apple.finder\tDisableAllAnimations\tdictionary\tlegacy-complex-value\n' > "$FAKE_DEFAULTS_STORE"
    before=$(cat "$FAKE_DEFAULTS_STORE")
    output=$(/bin/sh "$REPO_ROOT/scripts/ui_responsiveness_apply.sh" --legacy-test --yes 2>&1)
    assert_contains "$output" 'Skipping com.apple.finder DisableAllAnimations' 'unsupported prior type is reported and skipped'
    assert_equal "$before" "$(cat "$FAKE_DEFAULTS_STORE")" 'unsupported prior type is not mutated'
}

case $TEST_FILTER in
    common) run_common_tests ;;
    list) run_list_tests ;;
    state) run_state_tests ;;
    apply|restore) run_apply_restore_tests ;;
    ui) run_ui_tests; run_ui_edge_tests ;;
    failures) run_failure_path_tests ;;
    all)
        run_common_tests
        run_list_tests
        run_state_tests
        run_apply_restore_tests
        run_failure_path_tests
        run_ui_tests
        run_ui_edge_tests
        ;;
    *) printf 'Unknown test group: %s\n' "$TEST_FILTER" >&2; exit 2 ;;
esac

if [ "$FAILURES" -gt 0 ]; then
    printf '%s foreground-session test(s) failed.\n' "$FAILURES" >&2
    exit 1
fi
printf 'All requested foreground-session tests passed.\n'
