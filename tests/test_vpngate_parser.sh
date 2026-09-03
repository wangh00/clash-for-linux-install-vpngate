#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export CLASHCTL_HOME=$ROOT
export CLASHCTL_KERNEL=mihomo
. "$ROOT/scripts/lib/common.sh"
. "$ROOT/scripts/lib/vpngate.sh"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf 'proxies:\n' >"$tmp"
_vpngate_append_node "$ROOT/tests/fixtures/sample.ovpn" JP 203.0.113.10 "$tmp"

grep -Fq 'type: openvpn' "$tmp"
grep -Fq 'server: "203.0.113.10"' "$tmp"
grep -Fq 'proto: tcp' "$tmp"
grep -Fq 'data-ciphers:' "$tmp"
grep -Fq -- '- "AES-256-GCM"' "$tmp"
grep -Fq 'tls-auth: |' "$tmp"
grep -Fq 'key-direction: "1"' "$tmp"

printf 'vpngate parser test: ok\n'
