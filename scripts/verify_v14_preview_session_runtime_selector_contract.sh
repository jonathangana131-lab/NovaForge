#!/usr/bin/env bash
set -euo pipefail

select_ios_27_runtime() {
  jq -r '
    [.runtimes[]
      | select(.isAvailable == true)
      | select((.identifier // "") | startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))
      | select(((.version // "") | split(".")[0]) == "27")]
    | sort_by(.version | split(".") | map(tonumber))
    | last
    | .identifier // empty
  '
}

if [[ "${1:-}" == "--select" ]]; then
  select_ios_27_runtime
  exit 0
fi

mixed_platform_fixture='{
  "runtimes": [
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      "name": "iOS 27.0",
      "version": "27.0",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-9",
      "name": "watchOS 27.9",
      "version": "27.9",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.visionOS-27-8",
      "name": "visionOS 27.8",
      "version": "27.8",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
      "name": "iOS 27.2",
      "version": "27.2",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-5",
      "name": "iOS 27.5",
      "version": "27.5",
      "isAvailable": false
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-9",
      "name": "iOS 26.9",
      "version": "26.9",
      "isAvailable": true
    }
  ]
}'

selected=$(printf '%s' "$mixed_platform_fixture" | select_ios_27_runtime)
expected='com.apple.CoreSimulator.SimRuntime.iOS-27-2'
if [[ "$selected" != "$expected" ]]; then
  echo "Expected newest available iOS 27 runtime '$expected', got '$selected'" >&2
  exit 1
fi

non_ios_fixture='{
  "runtimes": [
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-4",
      "name": "watchOS 27.4",
      "version": "27.4",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-3",
      "name": "tvOS 27.3",
      "version": "27.3",
      "isAvailable": true
    }
  ]
}'

selected=$(printf '%s' "$non_ios_fixture" | select_ios_27_runtime)
if [[ -n "$selected" ]]; then
  echo "Expected no runtime when iOS 27 is absent, got '$selected'" >&2
  exit 1
fi

printf '%s\n' 'V14 Preview session runtime selector contract: PASS'
