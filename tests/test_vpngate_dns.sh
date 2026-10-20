#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
BIN_YQ=${BIN_YQ:-$ROOT/bin/yq}
[ -x "$BIN_YQ" ] || { echo "skip: yq not found: $BIN_YQ"; exit 0; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/scripts/lib/vpngate.sh"
CLASH_VPNGATE_DIR=$TMP
CLASH_VPNGATE_OVERLAY=$TMP/overlay.yaml
CLASH_VPNGATE_NODES_DIRECT=$TMP/direct.yaml
CLASH_VPNGATE_NODES_FRONT=$TMP/front.yaml
front='FRONT & # 测试'
printf 'proxies:\n  - name: VPNGate-test\n    type: socks5\n    server: 203.0.113.1\n    port: 1194\n' >"$CLASH_VPNGATE_NODES_DIRECT"
cp "$CLASH_VPNGATE_NODES_DIRECT" "$CLASH_VPNGATE_NODES_FRONT"

cat >"$TMP/base.yaml" <<'YAML'
dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  respect-rules: true
  nameserver: [223.5.5.5]
  nameserver-policy:
    "+.example.com": "https://1.1.1.1/dns-query#VPNGate-AUTO"
  proxy-server-nameserver-policy:
    "+.example.org": "https://1.1.1.1/dns-query#RULES"
  fallback: ["https://8.8.8.8/dns-query#RULES"]
  direct-nameserver: ["https://1.1.1.1/dns-query#RULES"]
YAML

for mode in bootstrap full; do
    _vpngate_write_overlay "$mode" "$front"
    "$BIN_YQ" -e '.dns."respect-rules" == false' "$CLASH_VPNGATE_OVERLAY" >/dev/null || {
        echo "missing DNS dependency guard: $mode" >&2; exit 1;
    }
    _vpngate_dns_guard_matches "$front"
    ! _vpngate_dns_guard_matches OTHER
    "$BIN_YQ" -e 'select(.dns."prefer-h3" == false) |
        select(.dns."nameserver-policy" == null) |
        select(.dns."proxy-server-nameserver-policy" == null) |
        select((.dns.fallback | length) == 0)' "$CLASH_VPNGATE_OVERLAY" >/dev/null
    [ "$("$BIN_YQ" -r '.dns.nameserver[]' "$CLASH_VPNGATE_OVERLAY" |
        grep -c '#VPNGate-DNS$')" -eq 2 ]
    [ "$("$BIN_YQ" -r '.dns."proxy-server-nameserver"[]' "$CLASH_VPNGATE_OVERLAY" |
        grep -c '#DIRECT$')" -eq 2 ]
    FRONT="$front" "$BIN_YQ" -e '.proxy-groups.append[] |
        select(.name == "VPNGate-DNS") |
        select(.hidden == true) | select((.proxies | length) == 1) | select(.proxies[0] == strenv(FRONT))' "$CLASH_VPNGATE_OVERLAY" >/dev/null
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . * $item)' \
        "$TMP/base.yaml" "$CLASH_VPNGATE_OVERLAY" >"$TMP/merged.yaml"
    "$BIN_YQ" -e 'select(.dns."respect-rules" == false) |
        select(.dns."nameserver-policy" == null) |
        select(.dns."proxy-server-nameserver-policy" == null) |
        select(.dns."enhanced-mode" == "fake-ip") |
        select(.dns.listen == "127.0.0.1:1053")' "$TMP/merged.yaml" >/dev/null
done

# 固定 DNS 路由不能再次被选为 VPNGate 前置，避免经前置/DNS 互相引用。
[ "$(printf '%s\n' FRONT VPNGate-DNS | _vpngate_filter_front_groups)" = FRONT ]
_vpngate_write_overlay off ''
[ "$("$BIN_YQ" -o=json -I=0 '.' "$CLASH_VPNGATE_OVERLAY")" = '{}' ]
! _vpngate_dns_guard_matches "$front"
"$BIN_YQ" eval-all '. as $item ireduce ({}; . * $item)' \
    "$TMP/base.yaml" "$CLASH_VPNGATE_OVERLAY" >"$TMP/off.yaml"
[ "$("$BIN_YQ" -o=json -I=0 '.dns' "$TMP/base.yaml")" = \
    "$("$BIN_YQ" -o=json -I=0 '.dns' "$TMP/off.yaml")" ]

echo 'vpngate DNS isolation tests: ok'
