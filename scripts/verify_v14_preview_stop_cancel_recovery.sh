#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

chat = Path("AgentPad/Views/ChatView.swift").read_text()
runtime_tests = Path("AgentPadTests/AgentRuntimeLifecycleTests.swift").read_text()
presentation_tests = Path("AgentPadTests/AgentSystemPresentationStoreTests.swift").read_text()
coordinator_tests = Path("AgentPadTests/AgentExecutionCoordinatorTests.swift").read_text()


def test_slice(source: str, signature: str) -> str:
    start = source.index(signature)
    next_test = source.find("\n    func test", start + len(signature))
    if next_test == -1:
        next_test = len(source)
    return source[start:next_test]


# The visible live-run Stop affordance must remain wired to the one ChatView
# stop authority instead of growing a second UI-local cancellation path.
stop_binding = "stop: stopActiveRun"
rail_anchor = "ComposerLiveRunRail("
if chat.count("private func stopActiveRun() {") != 1:
    raise SystemExit("ChatView must keep exactly one stopActiveRun authority")
rail_start = chat.index(rail_anchor)
if chat.find(stop_binding, rail_start, rail_start + 3_000) == -1:
    raise SystemExit("ComposerLiveRunRail Stop must remain bound to stopActiveRun")

stop_start = chat.index("    private func stopActiveRun() {")
stop_end_anchor = "\n    private var shouldShowJumpToLatestAccessory"
stop_end = chat.index(stop_end_anchor, stop_start)
stop = chat[stop_start:stop_end]

orchestration_guard = "if agentOrchestrationPresentation?.isActive == true {"
orchestration_cancel = "await agentSystemPresentation.cancelOrchestration("
orchestration_scope = "scope: agentPresentationScope"
runtime_fallback = "runtime.stopGenerating(context: modelContext)"
for token in (
    orchestration_guard,
    orchestration_cancel,
    orchestration_scope,
    runtime_fallback,
):
    if token not in stop:
        raise SystemExit(f"stopActiveRun is missing required cancellation token: {token}")
if not (
    stop.index(orchestration_guard)
    < stop.index(orchestration_cancel)
    < stop.index(orchestration_scope)
    < stop.index(runtime_fallback)
):
    raise SystemExit("orchestration cancellation must win before the normal runtime fallback")
if "return" not in stop[stop.index(orchestration_scope):stop.index(runtime_fallback)]:
    raise SystemExit("orchestration Stop must return before reaching the runtime fallback")

# Canonical activity cancellation is a different path: activity commands must
# continue to route through AgentSystemPresentationStore so stale command
# rejection and post-route projection refresh remain centralized.
activity_signature = "    private func handleActivityCommand(_ command: AgentActivityCommand) {"
activity_start = chat.index(activity_signature)
activity_end = chat.index("        case let .retry(retry):", activity_start)
cancel_branch = chat[activity_start:activity_end]
for token in (
    "case .cancel, .resolveApproval:",
    "_ = try await agentSystemPresentation.route(command)",
):
    if token not in cancel_branch:
        raise SystemExit(f"canonical activity cancellation lost presentation routing: {token}")

# Runtime Stop must synchronously clear working/queue state, reject a pending
# approval durably when a model context exists, and fence stale async work away
# from a fresh run.
active_stop = test_slice(
    runtime_tests,
    "func testStopGeneratingActiveRunClearsQueuedFollowUpsAndWorkingState() throws {",
)
for token in (
    "runtime.stopGenerating()",
    "XCTAssertFalse(runtime.isWorking)",
    "XCTAssertEqual(runtime.runState, .cancelled)",
    "XCTAssertEqual(runtime.queuedPromptCount, 0)",
    "XCTAssertTrue(runtime.wasInterrupted)",
):
    if token not in active_stop:
        raise SystemExit(f"active-run Stop regression lost required assertion: {token}")

pending_stop = test_slice(
    runtime_tests,
    "func testStopGeneratingRejectsPendingApprovalRun() throws {",
)
for token in (
    "runtime.stopGenerating(context: context)",
    "XCTAssertNil(runtime.pendingTool)",
    "XCTAssertFalse(runtime.isWorking)",
    "XCTAssertEqual(run.status, ToolRunStatus.rejected)",
    'XCTAssertEqual(run.output, "Cancelled while waiting for approval.")',
    "XCTAssertNotNil(run.completedAt)",
):
    if token not in pending_stop:
        raise SystemExit(f"pending-approval Stop regression lost required durable assertion: {token}")

stale_task = test_slice(
    runtime_tests,
    "func testCancelledStaleTaskCannotUntrackFreshStreamingRun() async throws {",
)
for token in (
    "runtime.stopGenerating()",
    "XCTAssertTrue(runtime.isWorking)",
    "XCTAssertEqual(runtime.runState, .running)",
    "XCTAssertTrue(runtime.debugHasTrackedTask",
):
    if token not in stale_task:
        raise SystemExit(f"cancelled-task reentry regression lost required assertion: {token}")
if stale_task.count("runtime.simulateStreamingStress()") < 2:
    raise SystemExit("cancelled-task reentry regression must start a replacement streaming run")

stale_completion = test_slice(
    runtime_tests,
    "func testStaleAsyncCompletionCannotOverwriteFreshRunState() async throws {",
)
for token in (
    "runtime.debugSimulateDelayedCompletionForActiveRun",
    "runtime.stopGenerating()",
    "runtime.simulateStreamingStress()",
    'XCTAssertNotEqual(runtime.activityTitle, "Stale completion applied")',
):
    if token not in stale_completion:
        raise SystemExit(f"stale-completion reentry regression lost required assertion: {token}")

# Full Forge/Ultra orchestration has an earlier cancellation phase than the
# normal provider/runtime path. Keep executable coverage that cancellation
# during workspace preparation starts no work and settles cleanup to a finite
# cancelled state.
orchestration_cancel_test = test_slice(
    presentation_tests,
    "func testUltraCodeCancelDuringCloneStartsNothingAndCleansAfterCancellation()",
)
for token in (
    "await store.cancelOrchestration(scope: scope)",
    ".stopping",
    ".rejected(.requestInvalid)",
    "XCTAssertTrue(harness.startedCommands.isEmpty)",
    "XCTAssertEqual(harness.cleanedWorkspaceNames.count, 1)",
    ".cancelled",
    "XCTAssertFalse(store.hasBlockingActivity)",
):
    if token not in orchestration_cancel_test:
        raise SystemExit(f"orchestration cancellation regression lost required assertion: {token}")

# The execution arbiter is the final recovery boundary: a cancelled queued run
# must vacate both mutation and local-inference queues so the immediate next
# run can acquire both resources and settle without stranded work.
coordinator_reentry = test_slice(
    coordinator_tests,
    "func testCancelledQueuedRunCannotBlockImmediateNextRun() async throws {",
)
for token in (
    "cancelledMutation.cancel()",
    "cancelledInference.cancel()",
    'afterCancellation.queuedMutationCountsByWorkspace["atlas"]',
    "XCTAssertEqual(afterCancellation.queuedLocalInferenceCount, 0)",
    'ownerDescription: "Next mutation"',
    'ownerDescription: "Next inference"',
    'afterReentry.activeMutationOwnersByWorkspace["atlas"]',
    'XCTAssertEqual(afterReentry.activeLocalInferenceOwner, "Next inference")',
    "XCTAssertFalse(afterReentry.hasQueuedWork)",
    "XCTAssertFalse(settled.hasActiveWork)",
    "XCTAssertFalse(settled.hasQueuedWork)",
):
    if token not in coordinator_reentry:
        raise SystemExit(f"coordinator cancellation/reentry regression lost required assertion: {token}")

print(
    "PASS: Preview Stop/cancel wiring remains singular at the live-run rail, "
    "routes orchestration/activity cancellation through presentation authority, "
    "keeps the normal runtime fallback, and retains executable cancellation/reentry regressions."
)
PY
