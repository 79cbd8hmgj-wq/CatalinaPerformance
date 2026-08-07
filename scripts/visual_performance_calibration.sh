#!/bin/sh
set -u

usage() {
    cat >&2 <<USAGE
Usage:
  $0 --setting SETTING_ID [--output PATH]
  $0 --restore-pending [--output PATH]

Calibration changes exactly one allowlisted visual preference, verifies it,
then restores or deletes the preference and verifies the original state.
USAGE
}

setting_id=
output_path=
yes=0
restore_pending=0

while [ "$#" -gt 0 ]; do
    case $1 in
        --setting)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            setting_id=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            output_path=$2
            shift 2
            ;;
        --yes)
            yes=1
            shift
            ;;
        --restore-pending)
            restore_pending=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
done

if [ "$restore_pending" -eq 1 ] && [ -n "$setting_id" ]; then
    printf 'Choose either --setting or --restore-pending, not both.\n' >&2
    exit 2
fi
if [ "$restore_pending" -eq 0 ] && [ -z "$setting_id" ]; then
    usage
    exit 2
fi
if [ "$yes" -eq 1 ] && [ "${CP_CALIBRATION_TEST_MODE:-0}" != "1" ]; then
    printf '%s\n' '--yes is restricted to the controlled calibration test fixture.' >&2
    exit 2
fi

DEFAULTS=${CP_DEFAULTS:-/usr/bin/defaults}
PYTHON=${CP_PYTHON:-/usr/bin/python}
STATE_DIR=${CP_VISUAL_CALIBRATION_STATE_DIR:-"$HOME/Library/Application Support/CatalinaPerformance/visual_performance_calibration"}
ACTIVE_STATE="$STATE_DIR/active-calibration.state"
PRIOR_VALUE_FILE="$STATE_DIR/prior-value.raw"

[ -x "$DEFAULTS" ] || {
    printf 'defaults executable is unavailable: %s\n' "$DEFAULTS" >&2
    exit 1
}
if [ ! -x "$PYTHON" ]; then
    PYTHON=$(command -v python3 2>/dev/null || true)
fi
[ -n "$PYTHON" ] && [ -x "$PYTHON" ] || {
    printf 'Python is required to normalize values and emit calibration JSON.\n' >&2
    exit 1
}

map_setting() {
    case $1 in
        finderAnimations)
            domain=com.apple.finder
            key=DisableAllAnimations
            applied_type=bool
            applied_value=true
            ;;
        dockLaunchAnimation)
            domain=com.apple.dock
            key=launchanim
            applied_type=bool
            applied_value=false
            ;;
        missionControlTransitions)
            domain=com.apple.dock
            key=expose-animation-duration
            applied_type=float
            applied_value=0.1
            ;;
        windowOpeningAnimations)
            domain=NSGlobalDomain
            key=NSAutomaticWindowAnimationsEnabled
            applied_type=bool
            applied_value=false
            ;;
        reduceMotion)
            domain=com.apple.universalaccess
            key=reduceMotion
            applied_type=bool
            applied_value=true
            ;;
        reduceTransparency)
            domain=com.apple.universalaccess
            key=reduceTransparency
            applied_type=bool
            applied_value=true
            ;;
        minimizeEffect)
            domain=com.apple.dock
            key=mineffect
            applied_type=string
            applied_value=scale
            ;;
        dockAutoHideDelay)
            domain=com.apple.dock
            key=autohide-delay
            applied_type=float
            applied_value=0
            ;;
        dockAutoHideAnimation)
            domain=com.apple.dock
            key=autohide-time-modifier
            applied_type=float
            applied_value=0
            ;;
        *)
            return 1
            ;;
    esac
}

type_name() {
    case $1 in
        *boolean*) printf 'bool\n' ;;
        *integer*) printf 'int\n' ;;
        *float*|*double*) printf 'float\n' ;;
        *string*) printf 'string\n' ;;
        *) printf 'unsupported\n' ;;
    esac
}

canonical_value() {
    value_type=$1
    value_file=$2
    "$PYTHON" - "$value_type" "$value_file" <<'PY'
from __future__ import print_function
import decimal
import sys

kind, path = sys.argv[1:3]
with open(path, 'rb') as handle:
    raw = handle.read()
if not isinstance(raw, str):
    raw = raw.decode('utf-8')
text = raw.strip()

if kind == 'string':
    value = text
elif kind == 'bool':
    lowered = text.lower()
    if lowered in ('1', 'true', 'yes'):
        value = 'true'
    elif lowered in ('0', 'false', 'no'):
        value = 'false'
    else:
        raise SystemExit(1)
elif kind == 'int':
    value = str(int(text, 10))
elif kind == 'float':
    number = decimal.Decimal(text)
    if not number.is_finite():
        raise SystemExit(1)
    value = format(number.normalize(), 'f')
    if value == '-0':
        value = '0'
else:
    raise SystemExit(1)
sys.stdout.write(value)
PY
}

prepare_state_directory() {
    if [ -L "$STATE_DIR" ]; then
        printf 'Calibration state directory may not be a symbolic link.\n' >&2
        return 1
    fi
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "$STATE_DIR" || return 1
    fi
    chmod 700 "$STATE_DIR" 2>/dev/null || return 1
    for protected_path in "$ACTIVE_STATE" "$PRIOR_VALUE_FILE"; do
        if [ -L "$protected_path" ]; then
            printf 'Calibration state files may not be symbolic links.\n' >&2
            return 1
        fi
    done
    return 0
}

read_observation() {
    observation_file=$1
    type_file=$2
    rm -f "$observation_file" "$type_file"
    if "$DEFAULTS" read "$domain" "$key" > "$observation_file" 2>/dev/null; then
        observation_exists=1
        if "$DEFAULTS" read-type "$domain" "$key" > "$type_file" 2>/dev/null; then
            observation_type=$(type_name "$(cat "$type_file")")
        else
            observation_type=unsupported
        fi
        if [ "$observation_type" != "unsupported" ]; then
            observation_normalized=$(canonical_value "$observation_type" "$observation_file" 2>/dev/null || printf 'UNPARSEABLE')
        else
            observation_normalized=UNSUPPORTED
        fi
    else
        observation_exists=0
        observation_type=absent
        observation_normalized=ABSENT
        : > "$observation_file"
        : > "$type_file"
    fi
}

write_typed_value() {
    value_type=$1
    value=$2
    case $value_type in
        bool)
            case $value in
                true|false) : ;;
                *) return 2 ;;
            esac
            "$DEFAULTS" write "$domain" "$key" -bool "$value" >/dev/null 2>&1
            ;;
        int)
            "$DEFAULTS" write "$domain" "$key" -int "$value" >/dev/null 2>&1
            ;;
        float)
            "$DEFAULTS" write "$domain" "$key" -float "$value" >/dev/null 2>&1
            ;;
        string)
            "$DEFAULTS" write "$domain" "$key" -string "$value" >/dev/null 2>&1
            ;;
        *)
            return 2
            ;;
    esac
}

values_equal() {
    compare_type=$1
    expected_normalized=$2
    actual_normalized=$3
    [ "$compare_type" != "unsupported" ] && [ "$expected_normalized" = "$actual_normalized" ]
}

persist_active_state() {
    temporary_state="$ACTIVE_STATE.new.$$"
    printf '1|%s|%s|%s|%s|%s|%s|%s\n' \
        "$setting_id" "$domain" "$key" "$prior_exists" "$prior_type" \
        "$applied_type" "$applied_value" > "$temporary_state" || return 1
    chmod 600 "$temporary_state" "$PRIOR_VALUE_FILE" 2>/dev/null || return 1
    cat "$temporary_state" >/dev/null 2>&1 || return 1
    mv "$temporary_state" "$ACTIVE_STATE" || return 1
    chmod 600 "$ACTIVE_STATE" 2>/dev/null || return 1
}

load_active_state() {
    [ -r "$ACTIVE_STATE" ] || return 1
    [ ! -L "$ACTIVE_STATE" ] && [ -r "$PRIOR_VALUE_FILE" ] && [ ! -L "$PRIOR_VALUE_FILE" ] || return 1

    IFS='|' read -r state_schema stored_setting stored_domain stored_key stored_prior_exists stored_prior_type stored_applied_type stored_applied_value < "$ACTIVE_STATE" || return 1
    [ "$state_schema" = "1" ] || return 1
    map_setting "$stored_setting" || return 1
    [ "$stored_domain" = "$domain" ] || return 1
    [ "$stored_key" = "$key" ] || return 1
    [ "$stored_applied_type" = "$applied_type" ] || return 1
    [ "$stored_applied_value" = "$applied_value" ] || return 1
    case $stored_prior_exists in 0|1) : ;; *) return 1 ;; esac
    case $stored_prior_type in absent|bool|int|float|string) : ;; *) return 1 ;; esac
    if [ "$stored_prior_exists" = "0" ] && [ "$stored_prior_type" != "absent" ]; then return 1; fi
    if [ "$stored_prior_exists" = "1" ] && [ "$stored_prior_type" = "absent" ]; then return 1; fi

    setting_id=$stored_setting
    prior_exists=$stored_prior_exists
    prior_type=$stored_prior_type
    return 0
}

capture_current_observation() {
    value_file=$1
    type_file=$2
    read_observation "$value_file" "$type_file"
    captured_exists=$observation_exists
    captured_type=$observation_type
    captured_normalized=$observation_normalized
    rm -f "$type_file"
}

restore_original_and_observe() {
    if [ "$prior_exists" = "0" ]; then
        "$DEFAULTS" delete "$domain" "$key" >/dev/null 2>&1
        restore_command_status=$?
    else
        if [ "$prior_type" = "bool" ]; then
            prior_value=$prior_normalized
        else
            prior_value=$(cat "$PRIOR_VALUE_FILE")
        fi
        write_typed_value "$prior_type" "$prior_value"
        restore_command_status=$?
    fi

    restored_value_file="$STATE_DIR/restored-value.$$"
    restored_type_file="$STATE_DIR/restored-type.$$"
    capture_current_observation "$restored_value_file" "$restored_type_file"
    restored_exists=$captured_exists
    restored_type=$captured_type
    restored_normalized=$captured_normalized
    rm -f "$restored_value_file"

    if [ "$prior_exists" = "0" ]; then
        [ "$restored_exists" -eq 0 ]
        return $?
    fi
    [ "$restored_exists" -eq 1 ] && [ "$restored_type" = "$prior_type" ] && \
        values_equal "$prior_type" "$prior_normalized" "$restored_normalized"
}

emit_json() {
    result_path=$1
    export CP_JSON_SETTING_ID="$setting_id"
    export CP_JSON_DOMAIN="$domain"
    export CP_JSON_KEY="$key"
    export CP_JSON_PRIOR_EXISTS="$prior_exists"
    export CP_JSON_PRIOR_TYPE="$prior_type"
    export CP_JSON_PRIOR_NORMALIZED="$prior_normalized"
    export CP_JSON_APPLIED_TYPE="$applied_type"
    export CP_JSON_APPLIED_VALUE="$applied_value"
    export CP_JSON_APPLY_STATUS="$apply_status"
    export CP_JSON_APPLY_VERIFIED="$apply_verified"
    export CP_JSON_APPLIED_EXISTS="$applied_observed_exists"
    export CP_JSON_APPLIED_OBSERVED_TYPE="$applied_observed_type"
    export CP_JSON_APPLIED_OBSERVED_NORMALIZED="$applied_observed_normalized"
    export CP_JSON_RESTORE_STATUS="$restore_status"
    export CP_JSON_RESTORE_VERIFIED="$restore_verified"
    export CP_JSON_RESTORED_EXISTS="$restored_exists"
    export CP_JSON_RESTORED_TYPE="$restored_type"
    export CP_JSON_RESTORED_NORMALIZED="$restored_normalized"
    export CP_JSON_STATE_PRESERVED="$state_preserved"
    export CP_JSON_ERROR="$error_message"

    "$PYTHON" - "$result_path" <<'PY'
from __future__ import print_function
import json
import os
import sys

path = sys.argv[1]

def optional_value(name):
    value = os.environ.get(name)
    if value in (None, '', 'ABSENT'):
        return None
    return value

value = {
    'schemaVersion': 1,
    'settingID': os.environ.get('CP_JSON_SETTING_ID'),
    'domain': os.environ.get('CP_JSON_DOMAIN'),
    'key': os.environ.get('CP_JSON_KEY'),
    'priorObservation': {
        'exists': os.environ.get('CP_JSON_PRIOR_EXISTS') == '1',
        'type': optional_value('CP_JSON_PRIOR_TYPE'),
        'normalizedValue': optional_value('CP_JSON_PRIOR_NORMALIZED'),
    },
    'requestedAppliedValue': {
        'type': os.environ.get('CP_JSON_APPLIED_TYPE'),
        'normalizedValue': os.environ.get('CP_JSON_APPLIED_VALUE'),
    },
    'applyStatus': int(os.environ.get('CP_JSON_APPLY_STATUS', '-1')),
    'applyVerified': os.environ.get('CP_JSON_APPLY_VERIFIED') == '1',
    'appliedObservation': {
        'exists': os.environ.get('CP_JSON_APPLIED_EXISTS') == '1',
        'type': optional_value('CP_JSON_APPLIED_OBSERVED_TYPE'),
        'normalizedValue': optional_value('CP_JSON_APPLIED_OBSERVED_NORMALIZED'),
    },
    'restoreStatus': int(os.environ.get('CP_JSON_RESTORE_STATUS', '-1')),
    'restoreVerified': os.environ.get('CP_JSON_RESTORE_VERIFIED') == '1',
    'restoredObservation': {
        'exists': os.environ.get('CP_JSON_RESTORED_EXISTS') == '1',
        'type': optional_value('CP_JSON_RESTORED_TYPE'),
        'normalizedValue': optional_value('CP_JSON_RESTORED_NORMALIZED'),
    },
    'statePreserved': os.environ.get('CP_JSON_STATE_PRESERVED') == '1',
    'errorMessage': os.environ.get('CP_JSON_ERROR') or None,
}
text = json.dumps(value, indent=2, sort_keys=True) + '\n'
if path == '-':
    sys.stdout.write(text)
else:
    directory = os.path.dirname(path) or '.'
    if not os.path.isdir(directory):
        raise SystemExit('Output directory does not exist: %s' % directory)
    temporary = os.path.join(directory, '.visual-calibration-result.%s.tmp' % os.getpid())
    with open(temporary, 'w') as handle:
        handle.write(text)
        handle.flush()
        try:
            os.fsync(handle.fileno())
        except OSError:
            pass
    os.rename(temporary, path)
PY
}

prepare_state_directory || {
    printf 'Unable to prepare Visual Performance calibration state.\n' >&2
    exit 1
}

if [ "$restore_pending" -eq 1 ]; then
    load_active_state || {
        printf 'No valid pending calibration state exists.\n' >&2
        exit 1
    }
    if [ "$prior_exists" = "1" ]; then
        prior_normalized=$(canonical_value "$prior_type" "$PRIOR_VALUE_FILE" 2>/dev/null || printf 'UNPARSEABLE')
    else
        prior_normalized=ABSENT
    fi
    apply_status=-1
    apply_verified=0
    applied_observed_exists=0
    applied_observed_type=absent
    applied_observed_normalized=ABSENT
    restore_status=1
    restore_verified=0
    restored_exists=0
    restored_type=absent
    restored_normalized=ABSENT
    state_preserved=1
    error_message='Pending calibration restoration failed.'
    if restore_original_and_observe; then
        restore_status=$restore_command_status
        restore_verified=1
        state_preserved=0
        error_message=
        rm -f "$ACTIVE_STATE" "$PRIOR_VALUE_FILE"
    else
        restore_status=$restore_command_status
    fi
    if [ -n "$output_path" ]; then result_target=$output_path; else result_target=-; fi
    emit_json "$result_target"
    [ "$restore_verified" -eq 1 ]
    exit $?
fi

map_setting "$setting_id" || {
    printf 'Unknown Visual Performance setting ID: %s\n' "$setting_id" >&2
    exit 2
}

if [ -e "$ACTIVE_STATE" ] || [ -e "$PRIOR_VALUE_FILE" ]; then
    printf 'A calibration restoration is pending. Run %s --restore-pending before calibrating another setting.\n' "$0" >&2
    exit 1
fi

if [ "$yes" -eq 0 ]; then
    printf 'Visual Performance calibration will temporarily change exactly one preference:\n'
    printf '  setting: %s\n  domain: %s\n  key: %s\n' "$setting_id" "$domain" "$key"
    printf 'The script will immediately restore the original typed value.\n'
    printf 'Type CALIBRATE to continue: '
    IFS= read -r confirmation || exit 1
    [ "$confirmation" = "CALIBRATE" ] || {
        printf 'Calibration cancelled.\n' >&2
        exit 1
    }
fi

prior_temp="$STATE_DIR/prior-value.new.$$"
prior_type_temp="$STATE_DIR/prior-type.$$"
read_observation "$prior_temp" "$prior_type_temp"
prior_exists=$observation_exists
prior_type=$observation_type
prior_normalized=$observation_normalized
rm -f "$prior_type_temp"

if [ "$prior_exists" -eq 1 ] && { [ "$prior_type" = "unsupported" ] || [ "$prior_normalized" = "UNPARSEABLE" ]; }; then
    rm -f "$prior_temp"
    printf 'Existing preference type or value cannot be restored safely; calibration refused.\n' >&2
    exit 1
fi

mv "$prior_temp" "$PRIOR_VALUE_FILE" || exit 1
persist_active_state || {
    rm -f "$PRIOR_VALUE_FILE"
    printf 'Unable to persist complete calibration state; no preference was changed.\n' >&2
    exit 1
}

apply_status=1
apply_verified=0
applied_observed_exists=0
applied_observed_type=absent
applied_observed_normalized=ABSENT
restore_status=1
restore_verified=0
restored_exists=0
restored_type=absent
restored_normalized=ABSENT
state_preserved=1
error_message='The applied value could not be verified.'

write_typed_value "$applied_type" "$applied_value"
apply_status=$?

applied_value_file="$STATE_DIR/applied-observed-value.$$"
applied_type_file="$STATE_DIR/applied-observed-type.$$"
capture_current_observation "$applied_value_file" "$applied_type_file"
applied_observed_exists=$captured_exists
applied_observed_type=$captured_type
applied_observed_normalized=$captured_normalized
rm -f "$applied_value_file"

if [ "$apply_status" -eq 0 ] && [ "$applied_observed_exists" -eq 1 ] && \
    [ "$applied_observed_type" = "$applied_type" ] && \
    values_equal "$applied_type" "$applied_value" "$applied_observed_normalized"; then
    apply_verified=1
    error_message=
fi

if restore_original_and_observe; then
    restore_status=$restore_command_status
    restore_verified=1
    state_preserved=0
    rm -f "$ACTIVE_STATE" "$PRIOR_VALUE_FILE"
else
    restore_status=$restore_command_status
    if [ -n "$error_message" ]; then
        error_message="$error_message Original preference restoration is unresolved."
    else
        error_message='Original preference restoration is unresolved.'
    fi
fi

if [ -n "$output_path" ]; then result_target=$output_path; else result_target=-; fi
emit_json "$result_target"

if [ "$apply_verified" -eq 1 ] && [ "$restore_verified" -eq 1 ]; then
    exit 0
fi
exit 1
