from pathlib import Path

chat_path = Path("AgentPad/Views/ChatView.swift")
presentation_path = Path("AgentPad/Views/AgentCanonicalActivityPresentation.swift")
tests_path = Path("AgentPadTests/AgentCanonicalActivityPresentationTests.swift")

chat = chat_path.read_text()
presentation = presentation_path.read_text()
tests = tests_path.read_text()

chat_mode_old = """            if agentRunPresentation.failure != nil ||
                agentRunPresentation.activeGroup?.state == .failed ||
                agentRunPresentation.activeGroup?.state == .rejected ||
                agentRunPresentation.activeGroup?.state == .cancelled ||
                agentRunPresentation.activeGroup?.state == .interrupted {
                return .failed
            }
"""
chat_mode_new = """            if agentRunPresentation.failure != nil ||
                AgentCanonicalRunSurfacePolicy.presentsFailure(
                    agentRunPresentation.activeGroup?.state
                ) {
                return .failed
            }
"""

accessory_old = """            if agentRunPresentation.failure != nil ||
                agentRunPresentation.activeGroup?.state == .failed ||
                agentRunPresentation.activeGroup?.state == .rejected ||
                agentRunPresentation.activeGroup?.state == .cancelled ||
                agentRunPresentation.activeGroup?.state == .interrupted {
                return .failure
            }
"""
accessory_new = """            if agentRunPresentation.failure != nil ||
                AgentCanonicalRunSurfacePolicy.presentsFailure(
                    agentRunPresentation.activeGroup?.state
                ) {
                return .failure
            }
"""

actionable_old = """            return canonicalRunIsActive ||
                agentRunPresentation.failure != nil ||
                agentRunPresentation.activeGroup?.state == .failed ||
                agentRunPresentation.activeGroup?.state == .cancelled ||
                agentRunPresentation.activeGroup?.state == .interrupted
"""
actionable_new = """            return canonicalRunIsActive ||
                agentRunPresentation.failure != nil ||
                AgentCanonicalRunSurfacePolicy.requiresRecoveryAction(
                    agentRunPresentation.activeGroup?.state
                )
"""

for label, old in [
    ("chat mode failure classifier", chat_mode_old),
    ("run accessory failure classifier", accessory_old),
    ("actionable recovery classifier", actionable_old),
]:
    count = chat.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source anchor, found {count}")

chat = chat.replace(chat_mode_old, chat_mode_new, 1)
chat = chat.replace(accessory_old, accessory_new, 1)
chat = chat.replace(actionable_old, actionable_new, 1)

policy_anchor = """/// Pure summary policy for provider-backed V1 messages that predate the
/// canonical journal. It is deliberately count/state based so the fallback
/// never determines lifecycle state by searching output text.
struct LegacyToolActivityBatchPresentation: Equatable {
"""
if presentation.count(policy_anchor) != 1:
    raise SystemExit("canonical presentation insertion anchor drifted")
if "enum AgentCanonicalRunSurfacePolicy {" in presentation:
    raise SystemExit("canonical run surface policy already exists")

policy = """/// Cross-surface terminal-state policy for the normal Chat shell.
///
/// User cancellation is a neutral, intentional terminal state. It must not
/// inherit failure chrome or recovery clearance merely because it stopped a
/// run. Rejections remain failure-presented, while only states with a useful
/// retry/continue recovery path stay actionable after the run settles.
enum AgentCanonicalRunSurfacePolicy {
    static func presentsFailure(_ state: AgentActivityState?) -> Bool {
        guard let state else { return false }
        switch state {
        case .failed, .rejected, .interrupted:
            true
        case .pending, .queued, .running, .awaitingApproval, .retrying,
             .succeeded, .cancelling, .cancelled:
            false
        }
    }

    static func requiresRecoveryAction(_ state: AgentActivityState?) -> Bool {
        guard let state else { return false }
        switch state {
        case .failed, .interrupted:
            true
        case .pending, .queued, .running, .awaitingApproval, .retrying,
             .succeeded, .rejected, .cancelling, .cancelled:
            false
        }
    }
}

"""
presentation = presentation.replace(policy_anchor, policy + policy_anchor, 1)

test_anchor = """    func testActiveToolReceiptsBecomeGranularLiveVerbs() {
"""
if tests.count(test_anchor) != 1:
    raise SystemExit("canonical activity test insertion anchor drifted")
if "testCanonicalRunSurfacePolicyKeepsUserStopOutOfFailurePresentation" in tests:
    raise SystemExit("neutral stop regression already exists")

regressions = """    func testCanonicalRunSurfacePolicyKeepsUserStopOutOfFailurePresentation() {
        XCTAssertFalse(
            AgentCanonicalRunSurfacePolicy.presentsFailure(.cancelled)
        )
        XCTAssertFalse(
            AgentCanonicalRunSurfacePolicy.presentsFailure(.cancelling)
        )
        XCTAssertFalse(
            AgentCanonicalRunSurfacePolicy.presentsFailure(nil)
        )
        XCTAssertTrue(
            AgentCanonicalRunSurfacePolicy.presentsFailure(.failed)
        )
        XCTAssertTrue(
            AgentCanonicalRunSurfacePolicy.presentsFailure(.rejected)
        )
        XCTAssertTrue(
            AgentCanonicalRunSurfacePolicy.presentsFailure(.interrupted)
        )
    }

    func testCanonicalRunSurfacePolicyKeepsUserStopOutOfRecoveryActions() {
        XCTAssertFalse(
            AgentCanonicalRunSurfacePolicy.requiresRecoveryAction(.cancelled)
        )
        XCTAssertFalse(
            AgentCanonicalRunSurfacePolicy.requiresRecoveryAction(.rejected)
        )
        XCTAssertFalse(
            AgentCanonicalRunSurfacePolicy.requiresRecoveryAction(nil)
        )
        XCTAssertTrue(
            AgentCanonicalRunSurfacePolicy.requiresRecoveryAction(.failed)
        )
        XCTAssertTrue(
            AgentCanonicalRunSurfacePolicy.requiresRecoveryAction(.interrupted)
        )
    }

"""
tests = tests.replace(test_anchor, regressions + test_anchor, 1)


def function_slice(source: str, signature: str, next_signature: str) -> str:
    start = source.index(signature)
    end = source.index(next_signature, start + len(signature))
    return source[start:end]


chat_mode = function_slice(
    chat,
    "    private var chatMode: ChatMode {",
    "    private var composerMode: ChatComposerMode {",
)
accessory = function_slice(
    chat,
    "    private var runAccessoryState: ChatRunAccessoryState {",
    "    private var hasCompletedRunEvidence: Bool {",
)
actionable = function_slice(
    chat,
    "    private var hasActionableRunState: Bool {",
    "    private var shouldShowQuickActions: Bool {",
)

for label, body in [
    ("chatMode", chat_mode),
    ("runAccessoryState", accessory),
    ("hasActionableRunState", actionable),
]:
    if "activeGroup?.state == .cancelled" in body:
        raise SystemExit(f"{label} still classifies cancelled directly")
if chat.count("AgentCanonicalRunSurfacePolicy.presentsFailure(") != 2:
    raise SystemExit("ChatView must share exactly two failure-presentation policy calls")
if chat.count("AgentCanonicalRunSurfacePolicy.requiresRecoveryAction(") != 1:
    raise SystemExit("ChatView must share exactly one recovery policy call")
if presentation.count("case .failed, .rejected, .interrupted:") != 1:
    raise SystemExit("failure presentation policy lost expected terminal states")
if presentation.count("case .failed, .interrupted:") != 1:
    raise SystemExit("recovery policy lost expected actionable terminal states")

chat_path.write_text(chat)
presentation_path.write_text(presentation)
tests_path.write_text(tests)
