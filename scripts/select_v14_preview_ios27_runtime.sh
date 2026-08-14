#!/bin/bash
set -euo pipefail

select_ios27_runtime() {
  jq -r '
    [.runtimes[]?
      | select(.isAvailable == true)
      | select((.identifier // "") | startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))
      | select((.name // "") | startswith("iOS "))
      | select(((.version // "") | split(".")[0]) == "27")]
    | sort_by(.version | split(".") | map(tonumber))
    | last
    | .identifier // empty
  '
}

run_self_test() {
  local selected
  selected=$(cat <<'JSON' | select_ios27_runtime
{
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
      "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-8",
      "name": "tvOS 27.8",
      "version": "27.8",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
      "name": "iOS 27.2",
      "version": "27.2",
      "isAvailable": false
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-6",
      "name": "iOS 26.6",
      "version": "26.6",
      "isAvailable": true
    }
  ]
}
JSON
  )

  if [ "$selected" != "com.apple.CoreSimulator.SimRuntime.iOS-27-0" ]; then
    echo "mixed-platform selector chose unexpected runtime: ${selected:-<empty>}" >&2
    exit 1
  fi

  selected=$(cat <<'JSON' | select_ios27_runtime
{
  "runtimes": [
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      "name": "iOS 27.0",
      "version": "27.0",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
      "name": "iOS 27.1",
      "version": "27.1",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.visionOS-27-9",
      "name": "visionOS 27.9",
      "version": "27.9",
      "isAvailable": true
    }
  ]
}
JSON
  )

  if [ "$selected" != "com.apple.CoreSimulator.SimRuntime.iOS-27-1" ]; then
    echo "iOS selector did not choose newest available iOS 27 runtime: ${selected:-<empty>}" >&2
    exit 1
  fi

  selected=$(cat <<'JSON' | select_ios27_runtime
{
  "runtimes": [
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-1",
      "name": "watchOS 27.1",
      "version": "27.1",
      "isAvailable": true
    }
  ]
}
JSON
  )

  if [ -n "$selected" ]; then
    echo "selector must fail closed when no iOS 27 runtime exists: $selected" >&2
    exit 1
  fi

  echo "V14 Preview iOS 27 runtime selector contract: PASS"
}

case "${1:-}" in
  --self-test)
    run_self_test
    ;;
  "")
    select_ios27_runtime
    ;;
  *)
    echo "usage: $0 [--self-test]" >&2
    exit 64
    ;;
esac
