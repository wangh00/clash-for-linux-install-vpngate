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
_sidecar_parse_uri "$uri"
[ "$SIDECAR_NODE_PROTOCOL" = shadowsocks ]
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

if _sidecar_parse_uri 'ss://bad@127.0.0.1:70000' 2>/dev/null; then
    echo 'invalid port unexpectedly accepted' >&2
    exit 1
fi

assert_share() {
    local protocol=$1 transport=$2 security=$3 share=$4 output
    output="$TMP/${protocol}-${transport}.json"
    _sidecar_parse_uri "$share"
    [ "$SIDECAR_NODE_PROTOCOL" = "$protocol" ]
    [ "$SIDECAR_NODE_TRANSPORT" = "$transport" ]
    [ "$SIDECAR_NODE_SECURITY" = "$security" ]
    _sidecar_write_config "$output" 127.0.0.1 10112
    [ "$($BIN_YQ -r '.outbounds[0].protocol' "$output")" = "$protocol" ]
    [ "$($BIN_YQ -r '.outbounds[0].streamSettings.network' "$output")" = "$transport" ]
    if [ -x "${BIN_XRAY_OVERRIDE:-}" ]; then
        "$BIN_XRAY_OVERRIDE" run -test -config "$output" >/dev/null
    fi
}

assert_share vless ws tls \
    'vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443?encryption=none&type=ws&security=tls&sni=example.com&host=cdn.example.com&path=%2Fx#VLESS-WS'
assert_share vmess grpc tls \
    'vmess://99c80931-f3f1-4f84-bffd-6eed6030f53d@example.com:443?encryption=auto&type=grpc&security=tls&sni=example.com&serviceName=test#VMess-gRPC'
assert_share trojan httpupgrade tls \
    'trojan://secret@example.com:443?type=httpupgrade&sni=example.com&host=example.com&path=%2Fu#Trojan-Upgrade'
_sidecar_parse_uri 'trojan://a+b@example.com:443#Plus'
[ "$SIDECAR_NODE_PASSWORD" = 'a+b' ]

vmess_json='{"v":"2","ps":"VMess-Legacy","add":"example.com","port":"443","id":"44efe52b-e143-46b5-a9e7-aadbfd77eb9c","aid":"0","scy":"auto","net":"ws","type":"none","host":"cdn.example.com","path":"/ws","tls":"tls","sni":"example.com"}'
assert_share vmess ws tls "vmess://$(printf '%s' "$vmess_json" | base64 | tr -d '\r\n')"

# Xray 26 已把旧 HTTP/H2 和 mKCP seed/header 参数迁移到新配置结构。
assert_share vless xhttp tls \
    'vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443?encryption=none&type=http&security=tls&sni=example.com&host=example.com&path=%2Fh2#VLESS-H2'
[ "$($BIN_YQ -r '.outbounds[0].streamSettings.xhttpSettings.mode' "$TMP/vless-xhttp.json")" = stream-one ]

assert_share vmess kcp none \
    'vmess://99c80931-f3f1-4f84-bffd-6eed6030f53d@example.com:443?encryption=auto&type=kcp&seed=seed&headerType=wireguard#VMess-KCP'
[ "$($BIN_YQ -r '.outbounds[0].streamSettings.finalmask.udp[0].type' "$TMP/vmess-kcp.json")" = mkcp-aes128gcm ]
[ "$($BIN_YQ -r '.outbounds[0].streamSettings.finalmask.udp[1].type' "$TMP/vmess-kcp.json")" = header-wireguard ]

assert_share vless tcp reality \
    'vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443?encryption=none&type=tcp&security=reality&sni=www.example.com&fp=chrome&pbk=cHDGCqCdtBpdd7-NRTJBcCJymRag7Hv2BSQO2tTsQVc&sid=0123456789abcdef&spx=%2F#VLESS-Reality'
[ "$($BIN_YQ -r '.outbounds[0].streamSettings.realitySettings.publicKey' "$TMP/vless-tcp.json")" = \
    cHDGCqCdtBpdd7-NRTJBcCJymRag7Hv2BSQO2tTsQVc ]

if _sidecar_parse_uri 'socks5://example.com:1080' 2>/dev/null; then
    echo 'unsupported protocol unexpectedly accepted' >&2
    exit 1
fi
if _sidecar_parse_uri 'trojan://bad@example.com:443#bad%ZZ' 2>/dev/null; then
    echo 'malformed URL escape unexpectedly accepted' >&2
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
