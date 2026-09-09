#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN_YQ=${BIN_YQ_OVERRIDE:-"$ROOT/../artifacts/yq.exe"}
[ -x "$BIN_YQ" ] || {
    echo "skip: yq not found: $BIN_YQ"
    exit 0
}

CLASH_CONFIG_MIXIN="$TMP/mixin.yaml"
printf '{}\n' >"$CLASH_CONFIG_MIXIN"
unset CLASHCTL_PROXY_USERNAME
export CLASHCTL_PROXY_PASSWORD=test-password

_set_env() { :; }
_okcat() { :; }
_errorcat() { return 1; }

. "$ROOT/scripts/lib/config.sh"
_configure_lan_proxy

[ "$($BIN_YQ -r '.authentication[0]' "$CLASH_CONFIG_MIXIN")" = \
    'admin:test-password' ]
[ "$($BIN_YQ -r '.mixed-port' "$CLASH_CONFIG_MIXIN")" = 7890 ]
[ "$($BIN_YQ -r '.bind-address' "$CLASH_CONFIG_MIXIN")" = '0.0.0.0' ]

echo 'default proxy auth test: ok'
