#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export CLASHCTL_HOME="$TMP/clashctl"
export CLASHCTL_KERNEL=mihomo
mkdir -p "$CLASHCTL_HOME/bin" "$CLASHCTL_HOME/resources"

YQ_PATH=${BIN_YQ_OVERRIDE:-"$ROOT/../artifacts/yq.exe"}
[ -x "$YQ_PATH" ] || {
    echo "skip: yq not found: $YQ_PATH"
    exit 0
}

. "$ROOT/scripts/lib/common.sh"
BIN_YQ=$YQ_PATH
. "$ROOT/scripts/lib/sidecar.sh"

uri='ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206OWdJWTNPblhBeXlSZnZLZHBSZWExdz09@131.143.214.101:34444?#Shadowsocks-2022-kddi'
_sidecar_parse_ss_uri "$uri"
[ "$SIDECAR_NODE_METHOD" = '2022-blake3-aes-128-gcm' ]
[ "$SIDECAR_NODE_PASSWORD" = '9gIY3OnXAyyRfvKdpRea1w==' ]
[ "$SIDECAR_NODE_SERVER" = '131.143.214.101' ]
[ "$SIDECAR_NODE_PORT" = 34444 ]
[ "$SIDECAR_NODE_NAME" = 'Shadowsocks-2022-kddi' ]

config="$TMP/config.json"
_sidecar_write_ss_config "$config" 0.0.0.0 7891
[ "$($BIN_YQ -r '.inbounds[0].protocol' "$config")" = mixed ]
[ "$($BIN_YQ -r '.inbounds[0].port' "$config")" = 7891 ]
[ "$($BIN_YQ -r '.outbounds[0].settings.servers[0].password' "$config")" = \
    '9gIY3OnXAyyRfvKdpRea1w==' ]

if _sidecar_parse_ss_uri 'ss://bad@127.0.0.1:70000' 2>/dev/null; then
    echo 'invalid port unexpectedly accepted' >&2
    exit 1
fi

# 两个方向都必须执行互斥保护。
_vpngate_state_get() { printf 'true\n'; }
service_is_active() { echo 'service start should not be reached' >&2; return 1; }
if _sidecar_start_locked 2>/dev/null; then
    echo 'sidecar start unexpectedly allowed while VPNGate is enabled' >&2
    exit 1
fi

. "$ROOT/scripts/cmd/vpngate.sh"
_vpngate_init_files() { :; }
_sidecar_is_active_or_enabled() { return 0; }
if _vpngate_on_locked 2>/dev/null; then
    echo 'VPNGate start unexpectedly allowed while sidecar is enabled' >&2
    exit 1
fi

echo 'sidecar tests: ok'
