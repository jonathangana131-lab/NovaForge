#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
AUDIT="$ROOT_DIR/scripts/codex-release-candidate-audit.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/novaforge-release-audit.XXXXXX")
APP="$TMP_DIR/NovaForge.app"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$APP"
cp /usr/bin/true "$APP/NovaForge"
plutil -create xml1 "$APP/Info.plist"
plutil -insert CFBundleIdentifier -string com.joey.NovaForge "$APP/Info.plist"
plutil -insert CFBundleExecutable -string NovaForge "$APP/Info.plist"
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$APP/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

EXPECTED_TEAM_ID='not set' "$AUDIT" "$APP" >"$TMP_DIR/pass.json"
grep -q '"status": "pass"' "$TMP_DIR/pass.json"
grep -Eq '"candidateManifestSHA256": "sha256:[0-9a-f]{64}"' "$TMP_DIR/pass.json"
grep -q '"bundleID": "com.joey.NovaForge"' "$TMP_DIR/pass.json"

# Code signatures do not bind filesystem mtimes. Move the executable timestamp
# behind repository sources to exercise the stale-candidate check without
# changing any signed byte.
touch -t 202001010000 "$APP/NovaForge"
set +e
EXPECTED_TEAM_ID='not set' "$AUDIT" "$APP" >"$TMP_DIR/stale.json" 2>"$TMP_DIR/stale.err"
command_status=$?
set -e
[ "$command_status" -eq 1 ]
grep -q '"status": "stale"' "$TMP_DIR/stale.json"
grep -Eq '"newerSourceCount": [1-9][0-9]*' "$TMP_DIR/stale.json"

plutil -replace CFBundleIdentifier -string com.example.Spoof "$APP/Info.plist"
set +e
EXPECTED_TEAM_ID='not set' "$AUDIT" "$APP" >"$TMP_DIR/spoof.out" 2>"$TMP_DIR/spoof.err"
command_status=$?
set -e
[ "$command_status" -eq 1 ]
grep -q 'expected com.joey.NovaForge' "$TMP_DIR/spoof.err"

echo "PASS: release-candidate audit binds bundle, platform, signing team, signature, source freshness, and manifest digest."
