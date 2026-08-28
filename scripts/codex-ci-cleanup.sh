#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 simulator-udid delete-created-0-or-1 /absolute/log-dir" >&2
  exit 2
fi

SIMULATOR_ID=$1
DELETE_CREATED=$2
LOG_DIR=$3
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$ROOT_DIR/scripts/codex-timeout-runner.pl"
mkdir -p "$LOG_DIR"

[[ "$SIMULATOR_ID" =~ ^[0-9A-Fa-f-]{36}$ ]] || {
  echo "cleanup received an invalid simulator identifier" >&2
  exit 2
}
[[ "$DELETE_CREATED" == 0 || "$DELETE_CREATED" == 1 ]] || {
  echo "cleanup delete flag must be 0 or 1" >&2
  exit 2
}

# Shutdown is idempotent at the lane boundary. Deletion is only allowed for a
# simulator created by this run; a pre-existing developer/runner device is
# never destroyed.
TIMEOUT_RUNNER_LABEL=ci-simulator-shutdown \
  "$RUNNER" 60 "$LOG_DIR/cleanup-simulator-shutdown.log" \
  /bin/sh -c 'xcrun simctl shutdown "$1" >/dev/null 2>&1 || true' sh "$SIMULATOR_ID" || true
if [ "$DELETE_CREATED" -eq 1 ]; then
  TIMEOUT_RUNNER_LABEL=ci-simulator-delete \
    "$RUNNER" 60 "$LOG_DIR/cleanup-simulator-delete.log" \
    xcrun simctl delete "$SIMULATOR_ID"
fi

lingering="$({
  pgrep -fl '(^|/)xcodebuild([[:space:]]|$)' || true
  pgrep -fl '(^|/)simctl([[:space:]]|$)' || true
  pgrep -fl 'NovaForge\.app/NovaForge' || true
} | sort -u)"
if [ -n "$lingering" ]; then
  echo "Lingering NovaForge CI processes detected after cleanup:" >&2
  printf '%s\n' "$lingering" >&2
  exit 1
fi
echo "PASS: CI simulator cleanup and process sweep completed."
