#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROBE="$ROOT/scripts/background_service_probe.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    needle=$1
    file=$2
    grep -F "$needle" "$file" >/dev/null 2>&1 || fail "missing required source: $needle"
}

assert_not_contains() {
    needle=$1
    file=$2
    if grep -F "$needle" "$file" >/dev/null 2>&1; then
        fail "prohibited source present: $needle"
    fi
}

[ -f "$PROBE" ] || fail "probe script missing"
/bin/sh -n "$PROBE" || fail "probe shell syntax"

assert_contains 'launchctl print gui/' "$PROBE"
assert_contains 'ps -ww -axo' "$PROBE"
assert_contains 'defaults export' "$PROBE"
assert_contains 'sw_vers' "$PROBE"
assert_contains 'sysctl -n hw.model' "$PROBE"
assert_contains 'chmod 600' "$PROBE"
assert_contains 'umask 077' "$PROBE"
assert_contains 'Darwin' "$PROBE"
assert_contains 'CANDIDATE SERVICE DETAILS' "$PROBE"
assert_contains 'CANDIDATE LAUNCH AGENT PLISTS' "$PROBE"
assert_contains 'ASSOCIATED APPLICATION IDENTIFIERS' "$PROBE"
assert_contains 'candidate_service_labels' "$PROBE"
assert_contains 'launchctl print "gui/$REQUESTING_UID/$label"' "$PROBE"
assert_contains "/usr/libexec/PlistBuddy -c 'Print :Label'" "$PROBE"
assert_contains '/usr/bin/plutil -p' "$PROBE"
assert_contains 'CFBundleIdentifier' "$PROBE"
assert_contains 'com.apple.photolibraryd' "$PROBE"
assert_contains 'com.apple.email.maild' "$PROBE"
assert_contains 'com.apple.IMDPersistenceAgent' "$PROBE"
assert_contains 'com.apple.corespeechd' "$PROBE"
assert_contains 'com.apple.bird' "$PROBE"
assert_not_contains 'killall' "$PROBE"
assert_not_contains 'launchctl disable' "$PROBE"
assert_not_contains 'launchctl bootout' "$PROBE"
assert_not_contains 'defaults write' "$PROBE"
assert_not_contains 'rm -f' "$PROBE"
assert_not_contains 'SIGKILL' "$PROBE"
assert_not_contains 'Mail/' "$PROBE"
assert_not_contains 'Messages/' "$PROBE"
assert_not_contains 'Photos Library' "$PROBE"
assert_not_contains 'Keychains/' "$PROBE"

printf 'PASS: Background service probe source contract\n'
