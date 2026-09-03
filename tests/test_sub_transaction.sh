#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN_YQ=${BIN_YQ:-"$ROOT/../artifacts/yq.exe"}
[ -x "$BIN_YQ" ] || {
    echo "skip: yq not found: $BIN_YQ"
    exit 0
}

CLASH_PROFILES_DIR="$TMP/profiles"
CLASH_PROFILES_META="$TMP/profiles.yaml"
CLASH_PROFILES_LOG="$TMP/profiles.log"
mkdir -p "$CLASH_PROFILES_DIR"
printf 'use: ""\nprofiles: []\n' >"$CLASH_PROFILES_META"

# shellcheck source=../scripts/cmd/sub.sh
. "$ROOT/scripts/cmd/sub.sh"

_okcat() { return 0; }
_errorcat() { return 1; }
_logging_sub() { printf '%s\n' "$*" >>"$CLASH_PROFILES_LOG"; }
_sub_use_locked() { return 1; }

download="$TMP/download.yaml"
printf 'proxies: []\n' >"$download"

set +e
_sub_add_locked tx https://example.invalid/sub true "$download" '' '' \
    http://127.0.0.1:7890
rc=$?
set -e

[ "$rc" -ne 0 ]
[ ! -e "$download" ]
[ "$($BIN_YQ '.profiles | length' "$CLASH_PROFILES_META")" -eq 0 ]
[ -z "$($BIN_YQ '.use // ""' "$CLASH_PROFILES_META")" ]

echo 'sub transaction test: ok'
