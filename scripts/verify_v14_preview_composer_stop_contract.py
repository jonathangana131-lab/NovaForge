#!/usr/bin/env python3
"""Fail-closed source-composition guard for the Preview Composer Stop path.

This intentionally proves only current source wiring. It does not replace Simulator,
visual, accessibility, provider, or physical-device cancellation acceptance.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(source: str, needle: str, scope: str) -> None:
    if needle not in source:
        fail(f"{scope} is missing required fragment: {needle}")


def swift_block(source: str, marker: str, scope: str) -> str:
    start = source.find(marker)
    if start < 0:
        fail(f"{scope} is missing marker: {marker}")
    brace = source.find("{", start)
    if brace < 0:
        fail(f"{scope} marker has no body: {marker}")

    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    fail(f"{scope} body is not balanced: {marker}")
    return ""


composer = read("AgentPad/Views/ChatComposer.swift")
chat = read("AgentPad/Views/ChatView.swift")
runtime = read("AgentPad/Services/AgentRuntime.swift")
activity = read("AgentPad/Services/RunActivityController.swift")

rail = swift_block(
    composer,
    "struct ComposerLiveRunRail: View",
    "ComposerLiveRunRail",
)
for fragment in (
    "Button(action: stop)",
    'Text("Stop")',
    '.accessibilityLabel("Stop generating")',
    '.accessibilityIdentifier("composerStopButton")',
):
    require(rail, fragment, "ComposerLiveRunRail")

# The visible Forge rail must route its Stop action through one centralized
# product handler instead of calling a legacy runtime directly from chrome.
require(chat, "ComposerLiveRunRail(", "ChatView")
require(chat, "stop: stopActiveRun", "ChatView Composer live-run rail")

stop_handler = swift_block(chat, "private func stopActiveRun()", "ChatView.stopActiveRun")
for fragment in (
    # Ultra/orchestrated canonical work owns an orchestration-level cancel.
    "agentSystemPresentation.cancelOrchestration(",
    # Normal canonical AgentSystem work owns the accepted group cancel command.
    "group.accepts(group.cancelCommand)",
    "handleActivityCommand(group.cancelCommand)",
    # DEBUG hosted-canary and legacy runtime fallbacks remain separately wired.
    "hostedTextCanarySession.stop()",
    "runtime.stopGenerating(context: modelContext)",
):
    require(stop_handler, fragment, "ChatView.stopActiveRun")

# The legacy/runtime-owned branch remains a real cancellation, not a failure
# presentation. This is intentionally source-level evidence around that branch;
# it does NOT redefine the canonical AgentSystem group's terminal presentation.
stop_runtime = swift_block(
    runtime,
    "func stopGenerating(context: ModelContext? = nil)",
    "AgentRuntime.stopGenerating",
)
for fragment in (
    "stopRequested = true",
    "currentTask?.cancel()",
    "liveStream.reset()",
    'setActivity("Paused"',
    'pushTrace("Paused by user"',
    "finishWorkingSession(.cancelled)",
    ".runPaused",
):
    require(stop_runtime, fragment, "AgentRuntime.stopGenerating")

finish_session = swift_block(
    runtime,
    "private func finishWorkingSession(_ conclusion: WorkConclusion)",
    "AgentRuntime.finishWorkingSession",
)
require(
    finish_session,
    "lifecycleEffects.runCancelled(terminalStatus)",
    "AgentRuntime.finishWorkingSession cancellation lifecycle",
)

cancel_activity = swift_block(
    activity,
    "func runCancelled(statusLine: String)",
    "RunActivityController.runCancelled",
)
for fragment in (
    'phase: "Paused"',
    "isWorking: false",
):
    require(cancel_activity, fragment, "RunActivityController.runCancelled")

print(
    "PASS: Preview Composer Stop remains wired to canonical orchestration, "
    "canonical group cancellation, hosted-canary, and legacy runtime branches; "
    "the legacy runtime cancellation path remains neutral Paused rather than failed."
)
