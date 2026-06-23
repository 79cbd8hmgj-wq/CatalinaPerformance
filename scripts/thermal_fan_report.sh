#!/bin/sh
# CatalinaPerformance read-only Thermal / Fan report.
# This script intentionally does not use sudo, control fans, write SMC values,
# load kexts, modify SIP, change kernel behavior, or alter system settings.

set -u

have_command() {
    command -v "$1" >/dev/null 2>&1
}

is_macos() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ]
}

print_section() {
    printf '\n== %s ==\n' "$1"
}

warn() {
    printf 'WARNING: %s\n' "$1"
}

ok() {
    printf 'OK: %s\n' "$1"
}

unavailable_builtin() {
    printf '“Unavailable with current read-only built-in method.”\n'
}

printf 'CatalinaPerformance Thermal / Fan Check (read-only)\n'
printf 'No sudo, fan control, SMC writes, kext loading, SIP changes, kernel changes, or system setting changes are performed.\n'

if ! is_macos; then
    printf 'Thermal / Fan monitoring currently supports macOS only. No system state was changed.\n'
    exit 0
fi

PMSET_THERM_OUTPUT=''
print_section 'Thermal Pressure / Limits'
if have_command pmset; then
    PMSET_THERM_OUTPUT=$(pmset -g therm 2>/dev/null || true)
    if [ -n "$PMSET_THERM_OUTPUT" ]; then
        printf '%s\n' "$PMSET_THERM_OUTPUT"
    else
        printf 'pmset -g therm returned no thermal data on this system.\n'
    fi
else
    printf 'pmset command not found; thermal pressure unavailable.\n'
fi

print_section 'Thermally Constrained Assessment'
if [ -n "$PMSET_THERM_OUTPUT" ]; then
    constrained_lines=$(printf '%s\n' "$PMSET_THERM_OUTPUT" | awk '
        BEGIN { found = 0 }
        /CPU_Speed_Limit|Scheduler_Limit|CPU_Scheduler_Limit/ {
            for (i = 1; i <= NF; i++) {
                value = $i
                gsub(/[^0-9]/, "", value)
                if (value != "" && value + 0 < 100) {
                    print $0
                    found = 1
                    break
                }
            }
        }
        END { exit found ? 0 : 1 }
    ' 2>/dev/null || true)
    if [ -n "$constrained_lines" ]; then
        warn 'The Mac appears thermally or power constrained based on pmset thermal limit values below 100%:'
        printf '%s\n' "$constrained_lines"
    elif printf '%s\n' "$PMSET_THERM_OUTPUT" | awk '{ line = tolower($0); if (line ~ /warning|critical|trap|limited|reduced|heavy/) found = 1 } END { exit found ? 0 : 1 }'; then
        warn 'pmset thermal output contains elevated-state wording. Review the Thermal Pressure / Limits section above.'
    else
        ok 'No obvious thermal constraint was detected in pmset -g therm output.'
    fi
else
    printf 'Unable to determine whether the Mac is thermally constrained because thermal status data is unavailable.\n'
fi

print_section 'CPU Temperature'
printf 'Built-in macOS read-only commands do not consistently expose CPU temperature on Catalina without privileged powermetrics sampling or SMC/third-party access.\n'
unavailable_builtin

print_section 'Fan RPM'
printf 'Built-in macOS read-only commands do not consistently expose fan RPM on Catalina without SMC/third-party access.\n'
unavailable_builtin

print_section 'Optional Read-Only Tool Checks'
if have_command powermetrics; then
    printf 'powermetrics is installed, but CatalinaPerformance does not run it here because thermal/SMC sampling commonly requires sudo or elevated privileges.\n'
else
    printf 'powermetrics command not found.\n'
fi

if have_command ioreg; then
    printf 'ioreg is installed. This report does not query or write SMC fan-control keys; fan control remains disabled.\n'
else
    printf 'ioreg command not found.\n'
fi

print_section 'Disabled / Not Implemented'
printf 'Aggressive fan behavior: Disabled / not implemented yet.\n'
printf 'Max fans while Performance Mode is ON: Disabled / not implemented yet.\n'
printf 'Custom fan curve: Disabled / not implemented yet.\n'
printf 'SMC write access: Disabled / not implemented yet.\n'

printf '\nReport complete. Thermal / Fan support is monitoring-only and made no system changes.\n'
