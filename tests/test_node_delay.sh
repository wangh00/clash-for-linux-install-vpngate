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
printf '0\n' >"$TMP/active"
printf '0\n' >"$TMP/maximum"

. "$ROOT/scripts/cmd/node.sh"
_okcat() { :; }
_failcat() { printf '%s\n' "$*" >&2; return 1; }
_node_print_delays() { cat; }
_node_members() {
    printf '%s\n' 'VPNGate-经前置-AUTO' \
        '[前置] VPNGate-test-1' '[前置] VPNGate-test-2' \
        '[前置] VPNGate-test-3' '[前置] VPNGate-test-4'
}
_node_curl() {
    local path=$2 active maximum
    printf '%s|%s\n' "$path" "${CLASHCTL_API_TIMEOUT:-}" >>"$TMP/requests"
    case "$path" in
    /group/*) printf '{}\n200'; return ;;
    esac
    {
        flock -x 9
        read -r active <"$TMP/active"
        active=$((active + 1))
        printf '%s\n' "$active" >"$TMP/active"
        read -r maximum <"$TMP/maximum"
        ((active > maximum)) && printf '%s\n' "$active" >"$TMP/maximum"
    } 9>>"$TMP/lock"
    sleep 0.1
    {
        flock -x 9
        read -r active <"$TMP/active"
        printf '%s\n' "$((active - 1))" >"$TMP/active"
    } 9>>"$TMP/lock"
    case "$path" in
    *test-4*) return 28 ;;
    esac
    printf '{"delay":123}'
}

CLASHCTL_VPNGATE_DELAY_CONCURRENCY=2 \
    _node_delay_group 'VPNGate-经前置' 'https://cp.cloudflare.com' 20000 >"$TMP/result"
[ "$(wc -l <"$TMP/result")" -eq 4 ]
grep -q $'\[前置\] VPNGate-test-4\t$' "$TMP/result"
[ "$(wc -l <"$TMP/requests")" -eq 4 ]
[ "$(cat "$TMP/maximum")" -le 2 ]
[ "$(cat "$TMP/maximum")" -ge 1 ]
! grep -q '^/group/' "$TMP/requests"
! grep -q 'VPNGate-经前置-AUTO' "$TMP/requests"
grep -v '|25$' "$TMP/requests" >"$TMP/incorrect-timeouts" || true
[ ! -s "$TMP/incorrect-timeouts" ]
[ "$(_node_delay_api_timeout 20000)" -eq 25 ]
CLASHCTL_API_TIMEOUT=40
[ "$(_node_delay_api_timeout 20000)" -eq 40 ]
unset CLASHCTL_API_TIMEOUT
_node_delay_one '[前置] VPNGate-test-1' 'timeout=8000&url=https%3A%2F%2Fcp.cloudflare.com' >/dev/null

# VPNGate 专用测试应通过当前实际出口，而非对嵌套组发 /group/delay。
unset CLASHCTL_VPNGATE_DELAY_URL
service_is_active() { :; }
_vpngate_route_leaf() { printf '%s\n' '[前置] VPNGate-test-1'; }
_vpngate_local_proxy_args() { VPNGATE_CURL_PROXY=(--proxy http://127.0.0.1:7890); }
curl() {
    printf '%s\n' "$@" >"$TMP/vpngate-test-args"
    printf '204\t0.42'
}
. "$ROOT/scripts/cmd/vpngate.sh"
clashvpngate test
grep -Fxq -- '--proxy' "$TMP/vpngate-test-args"
grep -Fxq -- 'http://127.0.0.1:7890' "$TMP/vpngate-test-args"
grep -Fxq -- 'https://cp.cloudflare.com' "$TMP/vpngate-test-args"
! grep -q '/group/' "$TMP/vpngate-test-args"
curl() { printf '502\t0.42'; }
if clashvpngate test >/dev/null 2>&1; then
    echo 'VPNGate test accepted HTTP 502' >&2
    exit 1
fi

echo 'node delay tests: ok'
