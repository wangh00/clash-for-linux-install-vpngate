#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
BIN_YQ=${BIN_YQ:-$ROOT/bin/yq}
if [ ! -x "$BIN_YQ" ]; then
    echo "skip: yq not found: $BIN_YQ"
    exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/scripts/cmd/vpngate.sh"

VPNGATE_GROUP_DIRECT=VPNGate-直连
VPNGATE_GROUP_FRONT=VPNGate-经前置
VPNGATE_GROUP_DIRECT_AUTO=VPNGate-直连-AUTO
VPNGATE_GROUP_FRONT_AUTO=VPNGate-经前置-AUTO
VPNGATE_GROUP_SMART_AUTO=VPNGate-智能自动
VPNGATE_GROUP_AUTO=VPNGate-AUTO
CLASH_VPNGATE_DIR=$TMP
CLASH_VPNGATE_NODES_DIRECT=$TMP/direct.yaml
CLASH_VPNGATE_NODES_FRONT=$TMP/front.yaml
CLASH_VPNGATE_OVERLAY=$TMP/overlay.yaml
CLASH_VPNGATE_API_RAW=$TMP/servers.csv
CLASH_VPNGATE_LOG=$TMP/update.log

cat >"$TMP/old-template.yaml" <<'YAML'
proxies:
  append:
    - name: "[前置] VPNGate-old"
      type: openvpn
      server: 203.0.113.1
      dialer-proxy: FRONT
proxy-groups:
  append:
    - name: VPNGate-经前置
      type: select
      proxies: [VPNGate-经前置-AUTO, "[前置] VPNGate-old"]
YAML
cat >"$TMP/new-template.yaml" <<'YAML'
proxies:
  append:
    - name: "[前置] VPNGate-new"
      type: openvpn
      server: 203.0.113.2
      dialer-proxy: FRONT
proxy-groups:
  append:
    - name: VPNGate-经前置
      type: select
      proxies: [VPNGate-经前置-AUTO, "[前置] VPNGate-new"]
YAML

declare -A STATE=() SELECTED=()
RELOADS=0
PROBE_OK=true
WRITE_OK=true
VERIFY_MODE=auto
reset_case() {
    cp "$TMP/old-template.yaml" "$CLASH_VPNGATE_OVERLAY"
    printf 'old\n' >"$CLASH_VPNGATE_NODES_DIRECT"
    printf 'old\n' >"$CLASH_VPNGATE_NODES_FRONT"
    printf 'old\n' >"$CLASH_VPNGATE_API_RAW"
    STATE=([enabled]=true)
    SELECTED=([VPNGate-直连]=VPNGate-直连-AUTO
              [VPNGate-经前置]='[前置] VPNGate-old'
              [VPNGate-AUTO]=VPNGate-经前置)
    RELOADS=0
    PROBE_OK=true
    WRITE_OK=true
    VERIFY_MODE=auto
}
_vpngate_init_files() { :; }
_vpngate_resolve_options() { VPNGATE_FRONT=FRONT; VPNGATE_COUNTRY=''; VPNGATE_LIMIT=0; }
_vpngate_front_exists() { :; }
tunstatus() { :; }
_vpngate_state_get() { printf '%s\n' "${STATE[$1]:-}"; }
_vpngate_state_set() { STATE[$1]=$2; }
_vpngate_state_set_num() { STATE[$1]=$2; }
_node_now() { printf '%s\n' "${SELECTED[$1]:-}"; }
_node_apply() { SELECTED[$1]=$2; }
_node_group_json() { printf '{"type":"Selector"}\n'; }
_vpngate_route_leaf() { printf '%s\n' '[前置] VPNGate-old'; }
_node_members() {
    case "$1" in
    "$VPNGATE_GROUP_DIRECT") printf '%s\n' "$VPNGATE_GROUP_DIRECT_AUTO" ;;
    "$VPNGATE_GROUP_FRONT")
        "$BIN_YQ" -r '."proxy-groups".append[] |
            select(.name == "VPNGate-经前置") | .proxies[]' "$CLASH_VPNGATE_OVERLAY" ;;
    "$VPNGATE_GROUP_AUTO") printf '%s\n' "$VPNGATE_GROUP_SMART_AUTO" "$VPNGATE_GROUP_DIRECT" "$VPNGATE_GROUP_FRONT" ;;
    esac
}
_vpngate_sync_nodes() {
    printf 'new\n' >"$CLASH_VPNGATE_NODES_DIRECT"
    printf 'new\n' >"$CLASH_VPNGATE_NODES_FRONT"
    printf 'new\n' >"$CLASH_VPNGATE_API_RAW"
    VPNGATE_NODES_CHANGED=true
    VPNGATE_GENERATED_COUNT=1
}
_vpngate_write_overlay() {
    [ "$WRITE_OK" = true ] || return 1
    cp "$TMP/new-template.yaml" "$CLASH_VPNGATE_OVERLAY"
}
_merge_config_reload() { RELOADS=$((RELOADS + 1)); CLASHCTL_CONFIG_APPLY_METHOD=hot-reload; }
_vpngate_probe_auto_candidates() {
    [ "$PROBE_OK" = true ] || return 1
    printf '%s\n' '[前置] VPNGate-new'
}
_vpngate_test_current_route() {
    case "$VERIFY_MODE" in
    auto) [ "${SELECTED[$VPNGATE_GROUP_FRONT]:-}" = "$VPNGATE_GROUP_FRONT_AUTO" ] ;;
    pin) [ "${SELECTED[$VPNGATE_GROUP_FRONT]:-}" = '[前置] VPNGate-new' ] ;;
    esac
}
_okcat() { :; }
_failcat() { return 1; }
_errorcat() { return 1; }

reset_case
_vpngate_update_locked
[ "$RELOADS" -eq 1 ]
[ "${SELECTED[$VPNGATE_GROUP_FRONT]}" = "$VPNGATE_GROUP_FRONT_AUTO" ]
[ "${STATE[last-update-result]}" = changed ]
[ "$(cat "$CLASH_VPNGATE_NODES_FRONT")" = new ]
_vpngate_overlay_has_proxy "$CLASH_VPNGATE_OVERLAY" '[前置] VPNGate-old'

reset_case
VERIFY_MODE=pin
_vpngate_update_locked
[ "${SELECTED[$VPNGATE_GROUP_FRONT]}" = '[前置] VPNGate-new' ]
[ "${STATE[last-update-result]}" = changed-pinned ]

reset_case
PROBE_OK=false
if _vpngate_update_locked; then
    echo 'update unexpectedly succeeded with no verified candidate' >&2
    exit 1
fi
[ "$RELOADS" -eq 2 ]
[ "${SELECTED[$VPNGATE_GROUP_FRONT]}" = '[前置] VPNGate-old' ]
[ "${STATE[last-update-result]}" = failed ]
[ "$(cat "$CLASH_VPNGATE_NODES_FRONT")" = old ]
cmp -s "$TMP/old-template.yaml" "$CLASH_VPNGATE_OVERLAY"

reset_case
WRITE_OK=false
if _vpngate_update_locked; then
    echo 'update unexpectedly succeeded after overlay generation failure' >&2
    exit 1
fi
[ "$RELOADS" -eq 0 ]
[ "$(cat "$CLASH_VPNGATE_NODES_FRONT")" = old ]
cmp -s "$TMP/old-template.yaml" "$CLASH_VPNGATE_OVERLAY"

echo 'vpngate update transaction tests: ok'
