#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CLASH_RESOURCES_DIR=$TMP
mkdir -p "$TMP/dist"
printf '<html><body></body></html>\n' >"$TMP/dist/index.html"

_errorcat() { printf '%s\n' "$*" >&2; return 1; }
. "$ROOT/scripts/lib/vpngate_ui.sh"
_vpngate_patch_zashboard
_vpngate_ui_static_check
grep -q 'const groupConcurrency = 3' "$TMP/dist/vpngate-ui.js"
grep -q 'const probeGroupBatched' "$TMP/dist/vpngate-ui.js"
! grep -q '\${api.base}/group/' "$TMP/dist/vpngate-ui.js"
if command -v node >/dev/null 2>&1; then
    node --check "$TMP/dist/vpngate-ui.js"
fi

echo 'vpngate UI tests: ok'
