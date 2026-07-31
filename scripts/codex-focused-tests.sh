#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail

# Compatibility entry point for older docs and performance tooling. The former
# 450-line unit-only runner has been replaced by the unified build-once lane
# system. Keep this wrapper so existing automation gets the fast unit lane.

ROOT_DIR="${0:A:h:h}"
export NOVAFORGE_TEST_VALIDATE_ONLY="${NOVAFORGE_TEST_VALIDATE_ONLY:-${FOCUSED_TEST_VALIDATE_ONLY:-0}}"
export NOVAFORGE_TEST_INCLUDE_PREFLIGHT="${NOVAFORGE_TEST_INCLUDE_PREFLIGHT:-0}"
export NOVAFORGE_TEST_INCLUDE_PACKAGE="${NOVAFORGE_TEST_INCLUDE_PACKAGE:-0}"
export LOG_DIR="${LOG_DIR:-$ROOT_DIR/QA/codex-focused-tests-$(date +%Y%m%d-%H%M%S)}"

exec "$ROOT_DIR/scripts/codex-test.sh" unit
