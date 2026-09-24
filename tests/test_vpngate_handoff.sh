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

cat >"$TMP/old.yaml" <<'YAML'
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
cat >"$TMP/new.yaml" <<'YAML'
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
    - name: VPNGate-经前置-AUTO
      type: url-test
      proxies: ["[前置] VPNGate-new"]
YAML

_vpngate_overlay_retain_proxy "$TMP/old.yaml" "$TMP/new.yaml" \
    '[前置] VPNGate-old' "$VPNGATE_GROUP_FRONT" "$TMP"
_vpngate_overlay_has_proxy "$TMP/new.yaml" '[前置] VPNGate-old'
"$BIN_YQ" -e '.proxies.append | length == 2' "$TMP/new.yaml" >/dev/null
"$BIN_YQ" -e '."proxy-groups".append[] | select(.name == "VPNGate-经前置") |
    .proxies[] | select(. == "[前置] VPNGate-old")' "$TMP/new.yaml" >/dev/null
! "$BIN_YQ" -e '."proxy-groups".append[] | select(.name == "VPNGate-经前置-AUTO") |
    .proxies[] | select(. == "[前置] VPNGate-old")' "$TMP/new.yaml" >/dev/null 2>&1

_node_members() {
    local i
    for i in {1..9}; do printf '[前置] VPNGate-new-%s\n' "$i"; done
}
_node_delay_member_rows() {
    local name
    shift 2
    printf '%s\n' "$#" >>"$TMP/batch-sizes"
    [ "${CLASHCTL_NODE_DELAY_CONCURRENCY:-}" = 3 ]
    for name in "$@"; do
        case "$name" in
        *-4) printf '%s\t250\n' "$name" ;;
        *) printf '%s\t\n' "$name" ;;
        esac
    done
}
candidate=$(_vpngate_probe_auto_candidates "$VPNGATE_GROUP_FRONT_AUTO")
[ "$candidate" = '[前置] VPNGate-new-4' ]
[ "$(cat "$TMP/batch-sizes")" = $'3\n3' ]

_node_now() { printf '%s\n' '[前置] VPNGate-old'; }
_node_apply() { printf '%s|%s\n' "$1" "$2" >>"$TMP/applied"; }
_vpngate_probe_auto_candidates() { printf '%s\n' '[前置] VPNGate-new-4'; }
_vpngate_test_current_route() {
    local count=0
    [ ! -e "$TMP/check-count" ] || read -r count <"$TMP/check-count"
    count=$((count + 1))
    printf '%s\n' "$count" >"$TMP/check-count"
    [ "$count" -eq 2 ]
}
_vpngate_handoff_after_reload "$VPNGATE_GROUP_FRONT" "$VPNGATE_GROUP_FRONT_AUTO" \
    '[前置] VPNGate-old' true
[ "$VPNGATE_HANDOFF_SELECTION" = pinned ]
[ "$(cat "$TMP/applied")" = $'VPNGate-经前置|VPNGate-经前置-AUTO\nVPNGate-经前置|[前置] VPNGate-new-4' ]

rm -f "$TMP/applied" "$TMP/check-count"
_vpngate_handoff_after_reload "$VPNGATE_GROUP_FRONT" "$VPNGATE_GROUP_FRONT_AUTO" \
    '[前置] VPNGate-old' true "$VPNGATE_GROUP_SMART_AUTO"
[ "$VPNGATE_HANDOFF_SELECTION" = pinned ]
[ "$(cat "$TMP/applied")" = $'VPNGate-AUTO|VPNGate-经前置\nVPNGate-经前置|VPNGate-经前置-AUTO\nVPNGate-AUTO|VPNGate-智能自动\nVPNGate-经前置|[前置] VPNGate-new-4\nVPNGate-AUTO|VPNGate-经前置' ]

echo 'vpngate handoff tests: ok'
