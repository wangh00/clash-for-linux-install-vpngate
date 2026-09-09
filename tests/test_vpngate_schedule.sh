#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
declare -A STATE=(
    [enabled]=false
    [auto-update-enabled]=true
    [auto-update-interval]=60
)
CALLS=''
WRITES=0

_vpngate_init_files() { :; }
_vpngate_state_get() { printf '%s\n' "${STATE[$1]:-}"; }
_vpngate_state_set() { STATE[$1]=$2; }
_vpngate_state_set_bool() { STATE[$1]=$2; }
_vpngate_state_set_num() { STATE[$1]=$2; }
_is_root() { return 0; }
_errorcat() { return 1; }
_okcat() { return 0; }
systemctl() {
    CALLS+="systemctl $*;"
    case "$1" in is-active | is-enabled) return 1 ;; esac
    return 0
}
export -f systemctl

. "$ROOT/scripts/lib/vpngate_schedule.sh"
_vpngate_schedule_write_units() { WRITES=$((WRITES + 1)); }

if _vpngate_schedule_start 60 2>/dev/null; then
    echo 'timer unexpectedly started while VPNGate was disabled' >&2
    exit 1
fi
[ -z "$CALLS" ]

_vpngate_schedule_resume_if_configured
[ "$WRITES" -eq 0 ]

STATE[enabled]=true
_vpngate_schedule_resume_if_configured
[ "$WRITES" -eq 1 ]
[[ "$CALLS" == *'systemctl enable clashctl-vpngate-update.timer;'* ]]
[[ "$CALLS" == *'systemctl restart clashctl-vpngate-update.timer;'* ]]

CALLS=''
_vpngate_schedule_pause
[[ "$CALLS" == *'systemctl disable --now clashctl-vpngate-update.timer;'* ]]
[ "${STATE[auto-update-enabled]}" = true ]

STATE[enabled]=false
CALLS=''
_vpngate_schedule_set_interval 90
[ "${STATE[auto-update-interval]}" = 90 ]
[ "$WRITES" -eq 1 ]
[ -z "$CALLS" ]

_vpngate_schedule_run
[[ "$CALLS" == *'systemctl disable --now clashctl-vpngate-update.timer;'* ]]
[ "${STATE[last-auto-result]}" = suspended-disabled ]

echo 'vpngate schedule tests: ok'
