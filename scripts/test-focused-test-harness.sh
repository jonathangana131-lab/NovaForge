#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$ROOT_DIR/scripts/codex-test.sh"
COMPATIBILITY_RUNNER="$ROOT_DIR/scripts/codex-focused-tests.sh"

for lane in smoke critical unit visual release; do
  output=$(NOVAFORGE_TEST_VALIDATE_ONLY=1 zsh "$RUNNER" "$lane")
  grep -q "Validated $lane lane contract." <<< "$output"
done

wrapper_output=$(FOCUSED_TEST_VALIDATE_ONLY=1 zsh "$COMPATIBILITY_RUNNER")
grep -q 'Validated unit lane contract.' <<< "$wrapper_output"

# Keep the fast lanes deliberately small. Release owns exhaustive coverage;
# visual owns PNG generation; assertion lanes rely on automatic failure shots.
grep -q 'Smoke lane grew past five UI journeys' "$RUNNER"
grep -q 'Critical lane grew past sixteen UI journeys' "$RUNNER"
grep -q 'NOVAFORGE_CAPTURE_MODE=off' "$RUNNER" || \
  grep -q 'NOVAFORGE_CAPTURE_MODE:-auto' "$RUNNER"
rg -q 'captureMode == "off"' "$ROOT_DIR/AgentPadUITests/AgentPadUITests.swift"
rg -q 'localWebArtifactFixtureReady' "$ROOT_DIR/AgentPad/Views/AppRootView.swift"
rg -q 'localWebArtifactFixtureReady' "$ROOT_DIR/AgentPadUITests/AgentPadUITests.swift"

if rg -n '^[[:space:]]*run_capped\(\)' "$ROOT_DIR/ci/verify.sh" "$ROOT_DIR/ci/pipeline.sh"; then
  echo "CI still defines a one-generation run_capped watchdog" >&2
  exit 1
fi
if rg -n 'pkill[[:space:]].*-P' "$ROOT_DIR/ci/verify.sh" "$ROOT_DIR/ci/pipeline.sh"; then
  echo "CI still uses one-generation pkill -P cleanup" >&2
  exit 1
fi

rg -q 'codex-test\.sh.*TEST_LANE' "$ROOT_DIR/ci/verify.sh"
rg -q 'codex-test\.sh.*visual' "$ROOT_DIR/ci/pipeline.sh"
rg -q 'codex-timeout-runner\.pl' "$RUNNER"
rg -q 'build-for-testing' "$RUNNER"
rg -q 'test-without-building' "$RUNNER"
rg -q '1 unit runner.*isolated UI runners' "$RUNNER"
rg -q 'test-ui-\$ordinal-\$test_name\.log' "$RUNNER"
rg -q 'UI_TEST_RESTART_INTERVAL' "$RUNNER"
rg -q 'refresh_simulator "\$batch"' "$RUNNER"
rg -q 'xctestrun_xcodebuild.*|| status=\$?' "$RUNNER"
rg -q 'swift test --package-path' "$RUNNER"
rg -q 'test-focused-test-harness\.sh' "$RUNNER"
rg -q 'MAX_HOST_LOAD_PER_CPU' "$ROOT_DIR/scripts/codex-performance-gate.sh"

echo "PASS: build-once test lanes are bounded, deterministic, screenshot-aware, and CI-wired."
