#!/bin/sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CALIBRATION="$ROOT/scripts/visual_performance_calibration.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[ -f "$CALIBRATION" ] || fail "visual performance calibration script is missing"
/bin/sh -n "$CALIBRATION" || fail "visual performance calibration script has invalid shell syntax"

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/visual-calibration-test.XXXXXX") || exit 1
trap 'rm -rf "$sandbox"' EXIT HUP INT TERM

fake_defaults="$sandbox/defaults"
state_file="$sandbox/defaults-state"
log_file="$sandbox/defaults-log"
calibration_state="$sandbox/calibration-state"

cat > "$fake_defaults" <<'SH'
#!/bin/sh
set -u

state=${CP_FAKE_DEFAULTS_STATE:?}
log=${CP_FAKE_DEFAULTS_LOG:?}
command=${1-}
shift || true
printf '%s' "$command" >> "$log"
for argument in "$@"; do
    printf '\t%s' "$argument" >> "$log"
done
printf '\n' >> "$log"

read_state() {
    [ -f "$state" ] || return 1
    IFS='|' read -r domain key type value < "$state" || return 1
}

case $command in
    read)
        [ "$#" -eq 2 ] || exit 64
        read_state || exit 1
        [ "$1" = "$domain" ] && [ "$2" = "$key" ] || exit 1
        printf '%s\n' "$value"
        ;;
    read-type)
        [ "$#" -eq 2 ] || exit 64
        read_state || exit 1
        [ "$1" = "$domain" ] && [ "$2" = "$key" ] || exit 1
        case $type in
            bool) printf 'Type is boolean\n' ;;
            int) printf 'Type is integer\n' ;;
            float) printf 'Type is float\n' ;;
            string) printf 'Type is string\n' ;;
            *) printf 'Type is %s\n' "$type" ;;
        esac
        ;;
    write)
        [ "$#" -eq 4 ] || exit 64
        domain=$1
        key=$2
        flag=$3
        value=$4
        case $flag in
            -bool) type=bool ;;
            -int) type=int ;;
            -float) type=float ;;
            -string) type=string ;;
            *) exit 65 ;;
        esac
        printf '%s|%s|%s|%s\n' "$domain" "$key" "$type" "$value" > "$state"
        ;;
    delete)
        [ "$#" -eq 2 ] || exit 64
        if read_state && [ "$1" = "$domain" ] && [ "$2" = "$key" ]; then
            rm -f "$state"
            exit 0
        fi
        exit 1
        ;;
    *)
        exit 64
        ;;
esac
SH
chmod +x "$fake_defaults"

run_calibration() {
    CP_DEFAULTS="$fake_defaults" \
    CP_FAKE_DEFAULTS_STATE="$state_file" \
    CP_FAKE_DEFAULTS_LOG="$log_file" \
    CP_VISUAL_CALIBRATION_STATE_DIR="$calibration_state" \
    CP_CALIBRATION_TEST_MODE=1 \
    /bin/sh "$CALIBRATION" "$@"
}

if run_calibration --setting unknown-id --yes >/dev/null 2>&1; then
    fail "unknown setting ID was accepted"
fi
if run_calibration --domain com.example --key unsafe --setting reduceMotion --yes >/dev/null 2>&1; then
    fail "user-supplied domain/key arguments were accepted"
fi
if CP_DEFAULTS="$fake_defaults" CP_FAKE_DEFAULTS_STATE="$state_file" CP_FAKE_DEFAULTS_LOG="$log_file" \
    CP_VISUAL_CALIBRATION_STATE_DIR="$calibration_state" \
    /bin/sh "$CALIBRATION" --setting reduceMotion --yes >/dev/null 2>&1; then
    fail "--yes was accepted outside controlled test mode"
fi

tab=$(printf '\t')

: > "$log_file"
rm -f "$state_file"
result_absent="$sandbox/reduce-motion.json"
run_calibration --setting reduceMotion --yes --output "$result_absent" >/dev/null || \
    fail "absent Boolean calibration failed"
[ ! -e "$state_file" ] || fail "originally absent preference was not deleted"
grep -F "write${tab}com.apple.universalaccess${tab}reduceMotion${tab}-bool${tab}true" "$log_file" >/dev/null || \
    fail "Boolean applied value did not use -bool true"
grep -F "delete${tab}com.apple.universalaccess${tab}reduceMotion" "$log_file" >/dev/null || \
    fail "originally absent preference was not deleted during restore"
grep -F '"applyVerified": true' "$result_absent" >/dev/null || fail "apply verification missing from JSON"
grep -F '"restoreVerified": true' "$result_absent" >/dev/null || fail "restore verification missing from JSON"

: > "$log_file"
printf 'com.apple.dock|mineffect|string|genie\n' > "$state_file"
result_string="$sandbox/minimize-effect.json"
run_calibration --setting minimizeEffect --yes --output "$result_string" >/dev/null || \
    fail "string calibration failed"
grep -F "write${tab}com.apple.dock${tab}mineffect${tab}-string${tab}scale" "$log_file" >/dev/null || \
    fail "minimize effect did not apply as a string"
grep -F "write${tab}com.apple.dock${tab}mineffect${tab}-string${tab}genie" "$log_file" >/dev/null || \
    fail "original string value was not restored exactly"
grep -F 'com.apple.dock|mineffect|string|genie' "$state_file" >/dev/null || \
    fail "fake defaults state did not return to original string value"


: > "$log_file"
printf 'com.apple.finder|DisableAllAnimations|bool|0\n' > "$state_file"
result_bool="$sandbox/finder-animations.json"
run_calibration --setting finderAnimations --yes --output "$result_bool" >/dev/null || \
    fail "existing Boolean calibration failed"
grep -F "write${tab}com.apple.finder${tab}DisableAllAnimations${tab}-bool${tab}true" "$log_file" >/dev/null || \
    fail "Finder animation calibration did not apply true"
grep -F "write${tab}com.apple.finder${tab}DisableAllAnimations${tab}-bool${tab}false" "$log_file" >/dev/null || \
    fail "original Boolean value was not restored with false"
grep -F '"normalizedValue": "false"' "$result_bool" >/dev/null || \
    fail "normalized prior/restored Boolean evidence missing"

: > "$log_file"
printf 'com.apple.dock|expose-animation-duration|float|0.25\n' > "$state_file"
result_float="$sandbox/mission-control.json"
run_calibration --setting missionControlTransitions --yes --output "$result_float" >/dev/null || \
    fail "floating-point calibration failed"
grep -F "write${tab}com.apple.dock${tab}expose-animation-duration${tab}-float${tab}0.1" "$log_file" >/dev/null || \
    fail "Mission Control duration did not apply as float 0.1"
grep -F "write${tab}com.apple.dock${tab}expose-animation-duration${tab}-float${tab}0.25" "$log_file" >/dev/null || \
    fail "original floating-point value was not restored"
grep -F 'com.apple.dock|expose-animation-duration|float|0.25' "$state_file" >/dev/null || \
    fail "floating-point state did not return to its original value"

rm -rf "$calibration_state"
mkdir -p "$calibration_state"
printf '1|reduceMotion|com.example.unsafe|reduceMotion|0|absent|bool|true\n' > \
    "$calibration_state/active-calibration.state"
: > "$calibration_state/prior-value.raw"
: > "$log_file"
if run_calibration --restore-pending >/dev/null 2>&1; then
    fail "tampered pending calibration state was accepted"
fi
if grep -F 'com.example.unsafe' "$log_file" >/dev/null; then
    fail "tampered state domain reached defaults"
fi
rm -rf "$calibration_state"

if grep -F 'com.example' "$log_file" >/dev/null; then
    fail "user-supplied domain reached defaults"
fi
if grep -E "${tab}-bool${tab}(0|1)$" "$log_file" >/dev/null; then
    fail "Boolean writes used numeric 0/1 instead of true/false"
fi

printf 'PASS: Visual Performance calibration operation boundary\n'
