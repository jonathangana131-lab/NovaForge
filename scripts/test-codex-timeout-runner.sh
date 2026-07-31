#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$ROOT_DIR/scripts/codex-timeout-runner.pl"
TREE_HELPER="$ROOT_DIR/scripts/tests/timeout-process-tree-helper.pl"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/novaforge-timeout-tests.XXXXXX")
PID_FILES=()

cleanup() {
  local pid_file=""
  local process_id=""
  for pid_file in "${PID_FILES[@]:-}"; do
    [ -f "$pid_file" ] || continue
    while read -r process_id _; do
      [[ "$process_id" =~ ^[0-9]+$ ]] || continue
      kill -KILL "$process_id" 2>/dev/null || true
    done < "$pid_file"
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" -eq "$expected" ] || fail "$label returned $actual; expected $expected"
}

wait_for_pid_count() {
  local pid_file="$1"
  local expected="$2"
  local attempt=0
  for attempt in $(seq 1 100); do
    if [ -f "$pid_file" ] && [ "$(wc -l < "$pid_file" | tr -d ' ')" -ge "$expected" ]; then
      return 0
    fi
    sleep 0.05
  done
  fail "timed out waiting for $expected helper PIDs in $pid_file"
}

assert_processes_gone() {
  local pid_file="$1"
  local attempt=0
  local process_id=""
  local role=""
  local alive=0
  for attempt in $(seq 1 100); do
    alive=0
    while read -r process_id role; do
      if kill -0 "$process_id" 2>/dev/null; then
        alive=1
      fi
    done < "$pid_file"
    [ "$alive" -eq 0 ] && return 0
    sleep 0.05
  done

  while read -r process_id role; do
    if kill -0 "$process_id" 2>/dev/null; then
      echo "still alive: pid=$process_id role=$role" >&2
    fi
  done < "$pid_file"
  fail "timeout supervisor left a descendant alive"
}

runner_env=(
  TIMEOUT_RUNNER_TERM_GRACE_SECONDS=0.2
  TIMEOUT_RUNNER_KILL_GRACE_SECONDS=0.5
  TIMEOUT_RUNNER_POLL_SECONDS=0.05
  TIMEOUT_RUNNER_HEARTBEAT_SECONDS=0
)

normal_log="$TMP_DIR/normal.log"
set +e
env "${runner_env[@]}" "$RUNNER" 5 "$normal_log" /bin/sh -c 'printf "normal-output\n"; exit 0'
status=$?
set -e
assert_status 0 "$status" "normal command"
grep -q '^normal-output$' "$normal_log" || fail "normal output was not captured"

nonzero_log="$TMP_DIR/nonzero.log"
set +e
env "${runner_env[@]}" "$RUNNER" 5 "$nonzero_log" /bin/sh -c 'printf "nonzero-output\n"; exit 7'
status=$?
set -e
assert_status 7 "$status" "nonzero command"
grep -q '^nonzero-output$' "$nonzero_log" || fail "nonzero output was not captured"

timeout_pid_file="$TMP_DIR/timeout.pids"
PID_FILES+=("$timeout_pid_file")
timeout_log="$TMP_DIR/timeout.log"
set +e
env "${runner_env[@]}" TIMEOUT_RUNNER_LABEL="escaped-tree-timeout" \
  "$RUNNER" 1 "$timeout_log" "$TREE_HELPER" "$timeout_pid_file" escaped
status=$?
set -e
assert_status 142 "$status" "timed-out command"
wait_for_pid_count "$timeout_pid_file" 3
assert_processes_gone "$timeout_pid_file"
grep -q '^helper-ready ' "$timeout_log" || fail "child output disappeared from timeout log"
grep -q '\[timeout\] Command exceeded 1s' "$timeout_log" || fail "timeout marker missing"
grep -q 'Sending TERM' "$timeout_log" || fail "TERM marker missing"
grep -q 'sending KILL' "$timeout_log" || fail "KILL marker missing"
grep -q 'fully drained' "$timeout_log" || fail "drain marker missing"
term_line=$(grep -n 'Sending TERM' "$timeout_log" | head -1 | cut -d: -f1)
kill_line=$(grep -n 'sending KILL' "$timeout_log" | head -1 | cut -d: -f1)
[ "$term_line" -lt "$kill_line" ] || fail "TERM/KILL diagnostics are out of order"

snapshot_target_pid_file="$TMP_DIR/snapshot-timeout-target.pids"
snapshot_helper_pid_file="$TMP_DIR/snapshot-timeout-helper.pids"
PID_FILES+=("$snapshot_target_pid_file" "$snapshot_helper_pid_file")
snapshot_log="$TMP_DIR/snapshot-timeout.log"
snapshot_started=$(perl -MTime::HiRes=time -e 'print time')
set +e
env "${runner_env[@]}" \
  TIMEOUT_RUNNER_LABEL="hung-process-snapshot" \
  TIMEOUT_RUNNER_TERM_GRACE_SECONDS=0.1 \
  TIMEOUT_RUNNER_KILL_GRACE_SECONDS=0.3 \
  TIMEOUT_RUNNER_SNAPSHOT_SECONDS=0.15 \
  TIMEOUT_RUNNER_SNAPSHOT_TEST_DELAY_SECONDS=5 \
  TIMEOUT_RUNNER_SNAPSHOT_TEST_PID_FILE="$snapshot_helper_pid_file" \
  "$RUNNER" 0.3 "$snapshot_log" "$TREE_HELPER" "$snapshot_target_pid_file" grouped
status=$?
set -e
snapshot_elapsed=$(perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$snapshot_started")
assert_status 142 "$status" "command with hung process snapshot"
perl -e 'exit($ARGV[0] < $ARGV[1] ? 0 : 1)' "$snapshot_elapsed" 3 \
  || fail "hung snapshot blocked the supervisor for ${snapshot_elapsed}s"
wait_for_pid_count "$snapshot_target_pid_file" 3
wait_for_pid_count "$snapshot_helper_pid_file" 1
assert_processes_gone "$snapshot_target_pid_file"
assert_processes_gone "$snapshot_helper_pid_file"
grep -q 'process snapshot exceeded 0.15s' "$snapshot_log" \
  || fail "snapshot deadline marker missing"
grep -q 'falling back to process-group signaling' "$snapshot_log" \
  || fail "snapshot fallback marker missing"
grep -q 'Sending TERM' "$snapshot_log" || fail "snapshot fallback did not send TERM"
grep -q 'sending KILL' "$snapshot_log" || fail "snapshot fallback did not send KILL"
grep -q 'fully drained' "$snapshot_log" || fail "snapshot fallback did not drain target group"

signal_pid_file="$TMP_DIR/signal.pids"
PID_FILES+=("$signal_pid_file")
signal_log="$TMP_DIR/signal.log"
env "${runner_env[@]}" TIMEOUT_RUNNER_LABEL="external-signal" \
  "$RUNNER" 30 "$signal_log" "$TREE_HELPER" "$signal_pid_file" escaped &
runner_pid=$!
wait_for_pid_count "$signal_pid_file" 3
kill -TERM "$runner_pid"
set +e
wait "$runner_pid"
status=$?
set -e
assert_status 143 "$status" "externally terminated wrapper"
assert_processes_gone "$signal_pid_file"
grep -q 'Received TERM' "$signal_log" || fail "external TERM marker missing"
grep -q 'fully drained' "$signal_log" || fail "external TERM did not drain the process tree"

echo "PASS: timeout runner bounds process snapshots, propagates status, and drains grouped and escaped descendants."
