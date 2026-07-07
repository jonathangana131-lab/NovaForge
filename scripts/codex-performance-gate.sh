#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail

ROOT_DIR="${0:A:h:h}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AgentPad.xcodeproj}"
SCHEME="${SCHEME:-AgentPad}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_SDK="${BUILD_SDK:-iphonesimulator}"
SIMULATOR_ID="${SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
BUNDLE_ID="${BUNDLE_ID:-com.joey.NovaForge}"
DESTINATION_TIMEOUT="${DESTINATION_TIMEOUT:-120}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
SIM_BOOT_TIMEOUT="${SIM_BOOT_TIMEOUT:-180}"
ONLY_ACTIVE_ARCH="${ONLY_ACTIVE_ARCH:-YES}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/QA/codex-performance-gate-$(date +%Y%m%d-%H%M%S)}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$LOG_DIR/DerivedData}"
XCTESTRUN_PATH="${XCTESTRUN_PATH:-}"
BUILD_IF_NEEDED="${BUILD_IF_NEEDED:-0}"
REQUIRE_QUIET_LANE="${REQUIRE_QUIET_LANE:-1}"
SHUTDOWN_SIMULATOR_AFTER_TESTS="${SHUTDOWN_SIMULATOR_AFTER_TESTS:-1}"
TIMEOUT_RUNNER="$ROOT_DIR/scripts/codex-timeout-runner.pl"

PERFORMANCE_LOG="${PERFORMANCE_LOG:-$LOG_DIR/performance.log}"
TEST_LOG="${TEST_LOG:-$LOG_DIR/ui-performance-test.log}"
SUMMARY_LOG="${SUMMARY_LOG:-$LOG_DIR/performance-summary.txt}"
BOOT_LOG="$LOG_DIR/simulator-bootstatus.log"
SHUTDOWN_LOG="$LOG_DIR/simulator-shutdown.log"
LOG_STREAM_PID=""

mkdir -p "$LOG_DIR"

cleanup_on_exit() {
  local exit_status=$?
  if [[ -n "$LOG_STREAM_PID" ]] && kill -0 "$LOG_STREAM_PID" 2>/dev/null; then
    kill "$LOG_STREAM_PID" 2>/dev/null || true
    sleep 0.2
    kill -9 "$LOG_STREAM_PID" 2>/dev/null || true
  fi
  xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ "$SHUTDOWN_SIMULATOR_AFTER_TESTS" == "1" ]]; then
    "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$SHUTDOWN_LOG" xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  return "$exit_status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_quiet_lane() {
  [[ "$REQUIRE_QUIET_LANE" == "1" ]] || return 0

  local active
  active="$(
    {
      pgrep -fl '[x]codebuild' || true
      pgrep -fl '[c]odex-fast-screenshot\.sh' || true
      pgrep -fl '[c]odex-sim-tour\.sh' || true
      pgrep -fl '[c]odex-focused-tests\.sh' || true
      pgrep -fl '[r]un-on-iphone\.sh' || true
    } | sort -u
  )"

  if [[ -n "$active" ]]; then
    echo "Another build/simulator helper appears active; refusing to start performance gate." >&2
    print -r -- "$active" >&2
    exit 75
  fi
}

discover_xctestrun() {
  if [[ -n "$XCTESTRUN_PATH" ]]; then
    [[ -f "$XCTESTRUN_PATH" ]] && print -r -- "$XCTESTRUN_PATH" && return 0
    return 1
  fi

  local -a path_files
  path_files=( "$ROOT_DIR"/QA/codex-focused-tests-*/xctestrun.path(N.om[1]) )
  if (( ${#path_files} > 0 )); then
    local from_file
    from_file="$(<"$path_files[1]")"
    if [[ -f "$from_file" ]]; then
      print -r -- "$from_file"
      return 0
    fi
  fi

  local -a candidates
  candidates=(
    "$ROOT_DIR"/QA/codex-focused-tests-*/DerivedData/Build/Products/${SCHEME}_*.xctestrun(N.om[1])
    "$HOME"/Library/Developer/Xcode/DerivedData/${SCHEME}-*/Build/Products/${SCHEME}_*.xctestrun(N.om[1])
  )
  if (( ${#candidates} > 0 )); then
    print -r -- "$candidates[1]"
    return 0
  fi

  return 1
}

prepare_simulator() {
  xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$SHUTDOWN_LOG" xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$BOOT_LOG" xcrun simctl bootstatus "$SIMULATOR_ID" -b
}

start_performance_log_stream() {
  : > "$PERFORMANCE_LOG"
  xcrun simctl spawn "$SIMULATOR_ID" log stream \
    --style compact \
    --level info \
    --predicate 'subsystem == "com.joey.NovaForge" && category == "Performance"' \
    > "$PERFORMANCE_LOG" 2>&1 &
  LOG_STREAM_PID="$!"
  sleep 1
}

run_ui_performance_test() {
  local -a package_args
  package_args=(
    -skipPackageUpdates
    -skipPackagePluginValidation
    -skipMacroValidation
  )

  if [[ -n "$XCTESTRUN_PATH" ]]; then
    "$TIMEOUT_RUNNER" "$TEST_TIMEOUT" "$TEST_LOG" xcodebuild \
      -xctestrun "$XCTESTRUN_PATH" \
      -destination "id=$SIMULATOR_ID" \
      -destination-timeout "$DESTINATION_TIMEOUT" \
      test-without-building \
      -only-testing:AgentPadUITests/AgentPadUITests/testProjectLiquidGlassPerformanceTraceFlow
    return
  fi

  if [[ "$BUILD_IF_NEEDED" != "1" ]]; then
    echo "No reusable .xctestrun found. Run scripts/codex-focused-tests.sh first, pass XCTESTRUN_PATH=..., or set BUILD_IF_NEEDED=1." >&2
    exit 2
  fi

  mkdir -p "$DERIVED_DATA_PATH"
  "$TIMEOUT_RUNNER" "$BUILD_TIMEOUT" "$TEST_LOG" xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk "$BUILD_SDK" \
    -destination "id=$SIMULATOR_ID" \
    -destination-timeout "$DESTINATION_TIMEOUT" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    "${package_args[@]}" \
    ONLY_ACTIVE_ARCH="$ONLY_ACTIVE_ARCH" \
    CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    test \
    -only-testing:AgentPadUITests/AgentPadUITests/testProjectLiquidGlassPerformanceTraceFlow
}

verify_performance_log() {
  env \
    MIN_PROJECT_IDLE_FPS="${MIN_PROJECT_IDLE_FPS:-45}" \
    MIN_PROJECT_SCROLL_FPS="${MIN_PROJECT_SCROLL_FPS:-40}" \
    MIN_CHAT_STREAMING_FPS="${MIN_CHAT_STREAMING_FPS:-40}" \
    IGNORE_INITIAL_TAB_SWITCH_SAMPLES="${IGNORE_INITIAL_TAB_SWITCH_SAMPLES:-1}" \
    MAX_TAB_SWITCH_AVERAGE_MS="${MAX_TAB_SWITCH_AVERAGE_MS:-900}" \
    MAX_TAB_SWITCH_PEAK_MS="${MAX_TAB_SWITCH_PEAK_MS:-1500}" \
    MAX_PROJECT_IDLE_AVG_WORST_FRAME_MS="${MAX_PROJECT_IDLE_AVG_WORST_FRAME_MS:-120}" \
    MAX_PROJECT_SCROLL_AVG_WORST_FRAME_MS="${MAX_PROJECT_SCROLL_AVG_WORST_FRAME_MS:-180}" \
    MAX_CHAT_STREAMING_AVG_WORST_FRAME_MS="${MAX_CHAT_STREAMING_AVG_WORST_FRAME_MS:-150}" \
    MAX_PROJECT_IDLE_PEAK_WORST_FRAME_MS="${MAX_PROJECT_IDLE_PEAK_WORST_FRAME_MS:-250}" \
    MAX_PROJECT_SCROLL_PEAK_WORST_FRAME_MS="${MAX_PROJECT_SCROLL_PEAK_WORST_FRAME_MS:-500}" \
    MAX_CHAT_STREAMING_PEAK_WORST_FRAME_MS="${MAX_CHAT_STREAMING_PEAK_WORST_FRAME_MS:-650}" \
    MAX_PROJECT_IDLE_HITCH_COUNT="${MAX_PROJECT_IDLE_HITCH_COUNT:-24}" \
    MAX_PROJECT_SCROLL_HITCH_COUNT="${MAX_PROJECT_SCROLL_HITCH_COUNT:-30}" \
    MAX_CHAT_STREAMING_HITCH_COUNT="${MAX_CHAT_STREAMING_HITCH_COUNT:-30}" \
    perl - "$PERFORMANCE_LOG" <<'PERL'
use strict;
use warnings;

my ($log_path) = @ARGV;
open my $fh, '<', $log_path or die "open $log_path failed: $!\n";

my %values;
my $last_sample = '';
while (my $line = <$fh>) {
    next unless $line =~ /\[NovaForgePerformance\]\s+(.+?):\s+(-?\d+(?:\.\d+)?)/;
    my ($name, $value) = ($1, $2 + 0);
    $name =~ s/\s+\z//;
    my $sample = "$name:$value";
    next if $sample eq $last_sample;
    $last_sample = $sample;
    push @{ $values{$name} }, $value;
}
close $fh;

my $ignored_tab_switch_samples = env_num('IGNORE_INITIAL_TAB_SWITCH_SAMPLES');
if ($ignored_tab_switch_samples > 0 && $values{'Tab Switch Duration ms'}) {
    splice @{ $values{'Tab Switch Duration ms'} }, 0, $ignored_tab_switch_samples;
}

sub env_num {
    my ($name) = @_;
    die "missing $name\n" unless exists $ENV{$name};
    die "$name must be numeric\n" unless $ENV{$name} =~ /\A-?\d+(?:\.\d+)?\z/;
    return $ENV{$name} + 0;
}

sub average {
    my ($items) = @_;
    my $sum = 0;
    $sum += $_ for @$items;
    return $sum / @$items;
}

sub maximum {
    my ($items) = @_;
    my $max = $items->[0];
    for my $value (@$items) {
        $max = $value if $value > $max;
    }
    return $max;
}

sub minimum {
    my ($items) = @_;
    my $min = $items->[0];
    for my $value (@$items) {
        $min = $value if $value < $min;
    }
    return $min;
}

my @failures;

sub require_average_at_least {
    my ($metric, $threshold_env) = @_;
    my $items = $values{$metric};
    if (!$items || !@$items) {
        push @failures, "$metric missing from performance log";
        return;
    }
    my $threshold = env_num($threshold_env);
    my $avg = average($items);
    if ($avg < $threshold) {
        push @failures, sprintf("%s average %.2f below %.2f", $metric, $avg, $threshold);
    }
}

sub require_max_at_most {
    my ($metric, $threshold_env) = @_;
    my $items = $values{$metric};
    if (!$items || !@$items) {
        push @failures, "$metric missing from performance log";
        return;
    }
    my $threshold = env_num($threshold_env);
    my $max = maximum($items);
    if ($max > $threshold) {
        push @failures, sprintf("%s max %.2f above %.2f", $metric, $max, $threshold);
    }
}

sub require_average_at_most {
    my ($metric, $threshold_env) = @_;
    my $items = $values{$metric};
    if (!$items || !@$items) {
        push @failures, "$metric missing from performance log";
        return;
    }
    my $threshold = env_num($threshold_env);
    my $avg = average($items);
    if ($avg > $threshold) {
        push @failures, sprintf("%s average %.2f above %.2f", $metric, $avg, $threshold);
    }
}

require_average_at_least('Project Idle FPS', 'MIN_PROJECT_IDLE_FPS');
require_average_at_least('Project Scroll FPS', 'MIN_PROJECT_SCROLL_FPS');
require_average_at_least('Chat Streaming FPS', 'MIN_CHAT_STREAMING_FPS');
require_average_at_most('Tab Switch Duration ms', 'MAX_TAB_SWITCH_AVERAGE_MS');
require_max_at_most('Tab Switch Duration ms', 'MAX_TAB_SWITCH_PEAK_MS');
require_average_at_most('Project Idle Worst Frame ms', 'MAX_PROJECT_IDLE_AVG_WORST_FRAME_MS');
require_average_at_most('Project Scroll Worst Frame ms', 'MAX_PROJECT_SCROLL_AVG_WORST_FRAME_MS');
require_average_at_most('Chat Streaming Worst Frame ms', 'MAX_CHAT_STREAMING_AVG_WORST_FRAME_MS');
require_max_at_most('Project Idle Worst Frame ms', 'MAX_PROJECT_IDLE_PEAK_WORST_FRAME_MS');
require_max_at_most('Project Scroll Worst Frame ms', 'MAX_PROJECT_SCROLL_PEAK_WORST_FRAME_MS');
require_max_at_most('Chat Streaming Worst Frame ms', 'MAX_CHAT_STREAMING_PEAK_WORST_FRAME_MS');
require_max_at_most('Project Idle Hitch Count', 'MAX_PROJECT_IDLE_HITCH_COUNT');
require_max_at_most('Project Scroll Hitch Count', 'MAX_PROJECT_SCROLL_HITCH_COUNT');
require_max_at_most('Chat Streaming Hitch Count', 'MAX_CHAT_STREAMING_HITCH_COUNT');

print "NovaForge performance gate summary\n";
print "Ignored initial tab switch samples: $ignored_tab_switch_samples\n";
for my $metric (sort keys %values) {
    my $items = $values{$metric};
    printf "%s: count=%d avg=%.2f min=%.2f max=%.2f\n",
        $metric, scalar(@$items), average($items), minimum($items), maximum($items);
}

if (@failures) {
    print "\nFailures:\n";
    print "- $_\n" for @failures;
    exit 1;
}

print "\nPerformance budgets passed.\n";
PERL
}

require_quiet_lane

if XCTESTRUN_PATH="$(discover_xctestrun)"; then
  echo "Using xctestrun: $XCTESTRUN_PATH"
elif [[ "$BUILD_IF_NEEDED" == "1" ]]; then
  XCTESTRUN_PATH=""
else
  echo "No reusable .xctestrun found. Run scripts/codex-focused-tests.sh first, pass XCTESTRUN_PATH=..., or set BUILD_IF_NEEDED=1." >&2
  exit 2
fi

echo "Preparing simulator $SIMULATOR_ID for performance gate."
prepare_simulator
start_performance_log_stream

echo "Running Liquid Glass performance UI flow."
if run_ui_performance_test; then
  echo "ok performance UI flow"
else
  exit_status=$?
  if (( exit_status == 142 )); then
    echo "Performance UI flow timed out after ${TEST_TIMEOUT}s." >&2
  else
    echo "Performance UI flow failed with status $exit_status." >&2
  fi
  echo "Last 120 lines from $TEST_LOG:" >&2
  tail -n 120 "$TEST_LOG" >&2
  exit "$exit_status"
fi

sleep 1
if [[ -n "$LOG_STREAM_PID" ]] && kill -0 "$LOG_STREAM_PID" 2>/dev/null; then
  kill "$LOG_STREAM_PID" 2>/dev/null || true
  wait "$LOG_STREAM_PID" 2>/dev/null || true
  LOG_STREAM_PID=""
fi

if verify_performance_log > "$SUMMARY_LOG"; then
  cat "$SUMMARY_LOG"
else
  cat "$SUMMARY_LOG" >&2
  echo "Performance log: $PERFORMANCE_LOG" >&2
  exit 1
fi

echo "Performance gate passed."
echo "Logs: $LOG_DIR"
