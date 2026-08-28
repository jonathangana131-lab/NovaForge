#!/bin/bash
# Visual-census lane. Unlike the retired hand-authored 46-shot script, this
# uses synchronized XCTest journeys, builds once, and publishes only the
# representative screenshots produced by those assertions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

RUN_ID="${GITHUB_RUN_ID:-local-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_ID="$(printf '%s' "$RUN_ID" | tr -cd '[:alnum:]_.-')"
[ -n "$RUN_ID" ] || { echo "Could not derive a safe CI run identity" >&2; exit 2; }
RUN_DIR="$ROOT_DIR/artifacts/visual/run-$RUN_ID"
CAPTURE_DIR="$RUN_DIR/captures"
LOG_DIR="$RUN_DIR/logs"
DERIVED_DATA="$ROOT_DIR/DerivedData/CI-Visual/run-$RUN_ID"
TIMEOUT_RUNNER="$ROOT_DIR/scripts/codex-timeout-runner.pl"
SIMULATOR_ID=""
CREATED_SIMULATOR=0
mkdir -p "$CAPTURE_DIR" "$LOG_DIR"

run_bounded() {
  local seconds="$1"
  local log_path="$2"
  shift 2
  TIMEOUT_RUNNER_LABEL=ci-visual \
    "$TIMEOUT_RUNNER" "$seconds" "$log_path" "$@"
}

publish_captures() {
  local publish_dir=""
  echo "==> Publishing visual proof to ci-shots"
  [ -f "$LOG_DIR/test.log" ] && tail -400 "$LOG_DIR/test.log" > "$CAPTURE_DIR/test-log-tail.txt"
  if [ -z "$(ls -A "$CAPTURE_DIR")" ]; then
    echo "nothing to publish"
    return 0
  fi
  if [ "${GITHUB_ACTIONS:-false}" != true ]; then
    echo "local run: visual proof is retained locally; ci-shots publish skipped"
    return 0
  fi
  AUTH_HEADER=$(git config --get http.https://github.com/.extraheader || true)
  [ -n "$AUTH_HEADER" ] || { echo "GitHub authentication header is missing" >&2; return 1; }
  [ -n "${GITHUB_REPOSITORY:-}" ] || { echo "GITHUB_REPOSITORY is missing" >&2; return 1; }
  publish_dir=$(mktemp -d "${TMPDIR:-/tmp}/novaforge-ci-shots.XXXXXX")
  cp -R "$CAPTURE_DIR"/. "$publish_dir"/ || { rm -rf -- "$publish_dir"; return 1; }
  git -C "$publish_dir" init -q -b ci-shots || { rm -rf -- "$publish_dir"; return 1; }
  git -C "$publish_dir" config user.name "github-actions[bot]" || { rm -rf -- "$publish_dir"; return 1; }
  git -C "$publish_dir" config user.email "41898282+github-actions[bot]@users.noreply.github.com" || { rm -rf -- "$publish_dir"; return 1; }
  git -C "$publish_dir" add -A || { rm -rf -- "$publish_dir"; return 1; }
  git -C "$publish_dir" commit -q -m "CI visual proof: run ${GITHUB_RUN_NUMBER:-local} (${GITHUB_SHA:-unknown})" || { rm -rf -- "$publish_dir"; return 1; }
  local push_status=0
  set +e
  run_bounded 120 "$LOG_DIR/ci-shots-push.log" \
    git -C "$publish_dir" -c "http.https://github.com/.extraheader=$AUTH_HEADER" \
    push --force "https://github.com/${GITHUB_REPOSITORY}.git" ci-shots
  push_status=$?
  set -e
  rm -rf -- "$publish_dir"
  return "$push_status"
}

cleanup() {
  local exit_status=$?
  if [[ "$SIMULATOR_ID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    "$ROOT_DIR/scripts/codex-ci-cleanup.sh" "$SIMULATOR_ID" "$CREATED_SIMULATOR" "$LOG_DIR" || {
      echo "CI cleanup/process sweep failed." >&2
      (( exit_status == 0 )) && exit_status=1
    }
  fi
  publish_captures || exit_status=1
  "$ROOT_DIR/scripts/codex-ci-evidence-manifest.sh" "$RUN_DIR" visual \
    "$([[ "$exit_status" -eq 0 ]] && echo pass || echo fail)" "$DERIVED_DATA" || {
    echo "Could not write the visual evidence manifest." >&2
    exit_status=1
  }
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> Selecting newest Xcode"
NEWEST_XCODE=$(find /Applications -maxdepth 1 -type d -name 'Xcode*.app' -print | sort -V | tail -1)
[ -n "$NEWEST_XCODE" ] || { echo "No Xcode installation found" >&2; exit 69; }
run_bounded 60 "$LOG_DIR/xcode-select.log" sudo -n xcode-select -s "$NEWEST_XCODE/Contents/Developer"

run_bounded 60 "$LOG_DIR/simctl-list.log" xcrun simctl list -j devices available
UDID=$(jq -r \
  '[.devices | to_entries[] | select(.key | contains("iOS")) | .value[] | select(.isAvailable == true and (.name | startswith("iPhone")))] | last | .udid // empty' \
  "$LOG_DIR/simctl-list.log")
if [ -z "$UDID" ]; then
  run_bounded 60 "$LOG_DIR/simctl-devicetypes.log" xcrun simctl list -j devicetypes
  DEVICE_TYPE=$(jq -r '[.devicetypes[] | select(.productFamily == "iPhone")] | last | .identifier // empty' \
    "$LOG_DIR/simctl-devicetypes.log")
  [ -n "$DEVICE_TYPE" ] || { echo "No compatible iPhone simulator type" >&2; exit 69; }
  run_bounded 60 "$LOG_DIR/simctl-create.log" xcrun simctl create "NovaForge Visual CI $RUN_ID" "$DEVICE_TYPE"
  UDID=$(tr -d '[:space:]' < "$LOG_DIR/simctl-create.log")
  CREATED_SIMULATOR=1
fi
[[ "$UDID" =~ ^[0-9A-Fa-f-]{36}$ ]] || { echo "Simulator selection returned an invalid UDID" >&2; exit 69; }
SIMULATOR_ID="$UDID"

echo "==> Running synchronized visual lane"
SIMULATOR_ID="$UDID" \
DERIVED_DATA_PATH="$DERIVED_DATA" \
LOG_DIR="$LOG_DIR" \
NOVAFORGE_CAPTURE_MODE=all \
NOVAFORGE_SCREENSHOT_DIR="$CAPTURE_DIR" \
TEST_TIMEOUT=3600 \
SHUTDOWN_SIMULATOR_AFTER_TESTS=1 \
zsh scripts/codex-test.sh visual

echo "==> Visual census passed"
