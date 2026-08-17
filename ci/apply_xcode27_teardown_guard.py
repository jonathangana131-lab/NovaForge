#!/usr/bin/env python3
"""Patch codex-test.sh to distinguish Xcode teardown hangs from failed tests.

Xcode 27 hosted runners can leave xcodebuild alive after XCTest has emitted the
final selected-suite pass sentinel. We recover only when that pass sentinel is
present and no XCTest failure sentinel exists. The transform replaces the whole
selection wrapper so malformed earlier revisions are repaired deterministically.
"""
from pathlib import Path

path = Path("scripts/codex-test.sh")
source = path.read_text(encoding="utf-8")

start_marker = "run_xctest_selection() {\n"
end_marker = "\nrun_critical_lane() {\n"
start = source.find(start_marker)
end = source.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit("run_xctest_selection boundaries drifted")
if source.find(start_marker, start + 1) != -1:
    raise SystemExit("run_xctest_selection start marker is not unique")

replacement = r'''run_xctest_selection() {
  local timeout="$1"
  local log_path="$2"
  local result_path="$3"
  shift 3
  local previous_result_path="$RESULT_BUNDLE_PATH"
  local selection_status=0

  if [[ "$WRITE_RESULT_BUNDLE" == "1" ]]; then
    RESULT_BUNDLE_PATH="$result_path"
    rm -rf -- "$RESULT_BUNDLE_PATH"
  fi

  xctestrun_xcodebuild "$timeout" "$log_path" "$@" || selection_status=$?

  # Xcode 27 hosted runners can strand xcodebuild after XCTest has already
  # emitted its final successful suite result. Recover only from that teardown
  # state: the pass sentinel must exist and no failure sentinel may exist.
  if (( selection_status != 0 )) && [[ -f "$log_path" ]]; then
    if grep -Fq "Test Suite 'Selected tests' passed" "$log_path" \
        && ! grep -Eq "Test (Case|Suite) '.*' failed|\*\* TEST FAILED \*\*|Testing failed:" "$log_path"; then
      local teardown_diag="$LOG_DIR/xcode27-teardown-$(basename "$log_path").txt"
      local pass_sentinel=""
      pass_sentinel="$(grep -F "Test Suite 'Selected tests' passed" "$log_path" | tail -1 || true)"
      {
        echo "XCTest completed successfully but xcodebuild did not terminate cleanly."
        echo "selection_status=$selection_status"
        echo "simulator=$SIMULATOR_ID"
        echo "xcode=$(xcodebuild -version | paste -sd ' ' -)"
        echo "pass_sentinel=$pass_sentinel"
        echo "---- host process snapshot ----"
        ps -axo pid,ppid,state,etime,command | grep -E 'xcodebuild|xctest|testmanagerd|CoreSimulator|NovaForge' || true
        echo "---- simulator child snapshot ----"
        xcrun simctl spawn "$SIMULATOR_ID" ps -axo pid,ppid,state,etime,command 2>&1 | grep -E 'xctest|NovaForge|testmanagerd' || true
      } > "$teardown_diag" 2>&1
      echo "RECOVERED: XCTest suite passed; Xcode 27 teardown returned status $selection_status. Diagnostic: $teardown_diag"
      selection_status=0
    fi
  fi

  RESULT_BUNDLE_PATH="$previous_result_path"
  return "$selection_status"
}
'''

source = source[:start] + replacement + source[end:]
selection = source[start:source.find(end_marker, start)]

for needle in (
    "RECOVERED: XCTest suite passed; Xcode 27 teardown",
    "pass_sentinel=\"$(grep -F",
    "selection_status=0",
):
    if needle not in selection:
        raise SystemExit(f"post-transform selection validation missing {needle!r}")

# One initial zero plus one verified-recovery zero are expected inside this
# function. Anything else means the wrapper changed unexpectedly.
if selection.count("selection_status=0") != 2:
    raise SystemExit(
        f"unexpected selection_status=0 count: {selection.count('selection_status=0')}"
    )

# The malformed transform wrote literal backslash-n tokens into the shell
# condition. Do not permit those to survive this repair.
if ")) \\n" in selection:
    raise SystemExit("literal backslash-n survived teardown-guard repair")

path.write_text(source, encoding="utf-8")
print(f"replaced syntax-safe run_xctest_selection in {path}")
