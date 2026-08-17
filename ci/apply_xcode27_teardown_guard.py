#!/usr/bin/env python3
"""Patch codex-test.sh to distinguish Xcode teardown hangs from failed tests.

Xcode 27 hosted runners can leave xcodebuild alive after XCTest has emitted the
final selected-suite pass sentinel. We only recover from a nonzero/timeout when
that exact sentinel exists and no XCTest failure sentinel exists. Diagnostics are
captured so this remains visible instead of silently masking teardown debt.
"""
from pathlib import Path

path = Path("scripts/codex-test.sh")
source = path.read_text(encoding="utf-8")

old = '''  xctestrun_xcodebuild "$timeout" "$log_path" "$@" || selection_status=$?\n  RESULT_BUNDLE_PATH="$previous_result_path"\n  return "$selection_status"\n}\n'''
new = '''  xctestrun_xcodebuild "$timeout" "$log_path" "$@" || selection_status=$?\n\n  # Xcode 27 can strand the test host after XCTest has fully completed. Treat\n  # that as teardown debt, not a test failure, but only under a fail-closed\n  # proof: the final Selected-tests suite must have passed and no XCTest failure\n  # sentinel may exist in the captured log. The timeout runner has already\n  # drained the xcodebuild process tree before control reaches this point.\n  if (( selection_status != 0 )) \\n      && [[ -f "$log_path" ]] \\n      && grep -Fq "Test Suite 'Selected tests' passed" "$log_path" \\n      && ! grep -Eq "Test (Case|Suite) '.*' failed|\\*\\* TEST FAILED \\*\\*|Testing failed:" "$log_path"; then\n    local teardown_diag="$LOG_DIR/xcode27-teardown-$(basename "$log_path").txt"\n    {\n      echo "XCTest completed successfully but xcodebuild did not terminate cleanly."\n      echo "selection_status=$selection_status"\n      echo "simulator=$SIMULATOR_ID"\n      echo "xcode=$(xcodebuild -version | tr '\\n' ' ')"\n      echo "pass_sentinel=$(grep -F "Test Suite 'Selected tests' passed" "$log_path" | tail -1)"\n      echo "---- host process snapshot ----"\n      ps -axo pid,ppid,state,etime,command | grep -E 'xcodebuild|xctest|testmanagerd|CoreSimulator|NovaForge' || true\n      echo "---- simulator child snapshot ----"\n      xcrun simctl spawn "$SIMULATOR_ID" ps -axo pid,ppid,state,etime,command 2>&1 | grep -E 'xctest|NovaForge|testmanagerd' || true\n    } > "$teardown_diag" 2>&1\n    echo "RECOVERED: XCTest suite passed; Xcode 27 teardown returned status $selection_status. Diagnostic: $teardown_diag"\n    selection_status=0\n  fi\n\n  RESULT_BUNDLE_PATH="$previous_result_path"\n  return "$selection_status"\n}\n'''

if old in source:
    if source.count(old) != 1:
        raise SystemExit(f"run_xctest_selection marker not unique: {source.count(old)}")
    source = source.replace(old, new, 1)
elif "RECOVERED: XCTest suite passed; Xcode 27 teardown" not in source:
    raise SystemExit("run_xctest_selection marker drifted")

for needle in (
    "Test Suite 'Selected tests' passed",
    "xcode27-teardown-$(basename",
    "selection_status=0",
):
    if needle not in source:
        raise SystemExit(f"post-transform validation missing {needle!r}")

path.write_text(source, encoding="utf-8")
print(f"patched {path}")
