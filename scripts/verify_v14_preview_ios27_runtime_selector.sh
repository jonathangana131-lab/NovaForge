#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELECTOR="$ROOT_DIR/v14-preview-ios27-runtime-selector.jq"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$SELECTOR" ] || fail "missing selector: $SELECTOR"
command -v jq >/dev/null 2>&1 || fail "jq is required"

mixed_platforms='{
  "runtimes": [
    {"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-27-9","name":"watchOS 27.9","version":"27.9","buildversion":"W279","isAvailable":true},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2","name":"iOS 27.2","version":"27.2","buildversion":"I272","isAvailable":true},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.visionOS-27-8","name":"visionOS 27.8","version":"27.8","buildversion":"V278","isAvailable":true},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-10","name":"iOS 27.10","version":"27.10","buildversion":"I2710","isAvailable":true},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-28-0","name":"iOS 28.0","version":"28.0","buildversion":"I280","isAvailable":true},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-11","name":"iOS 27.11","version":"27.11","buildversion":"I2711","isAvailable":false}
  ]
}'

selected=$(printf '%s' "$mixed_platforms" | jq -rf "$SELECTOR")
[ "$selected" = "com.apple.CoreSimulator.SimRuntime.iOS-27-10" ] || \
  fail "mixed-platform fixture selected '$selected' instead of newest available iOS 27 runtime"

non_ios_only='{
  "runtimes": [
    {"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-27-4","name":"watchOS 27.4","version":"27.4","buildversion":"W274","isAvailable":true},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-27-5","name":"tvOS 27.5","version":"27.5","buildversion":"T275","isAvailable":true},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-6","name":"iOS 26.6","version":"26.6","buildversion":"I266","isAvailable":true}
  ]
}'

selected=$(printf '%s' "$non_ios_only" | jq -rf "$SELECTOR")
[ -z "$selected" ] || fail "selector must fail closed when no available iOS 27 runtime exists; got '$selected'"

printf 'PASS: Preview relaunch runtime selector is iOS-27-specific and mixed-platform deterministic.\n'
