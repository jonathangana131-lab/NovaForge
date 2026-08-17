#!/usr/bin/env python3
"""One-shot, fail-closed transform for local inference context virtualization.

Canonical provider history remains fully validated and authoritative. This patch
only bounds the messages handed to the physical local model after validation,
retaining a cache-stable instruction prefix and the active recent tail.
"""
from pathlib import Path

SOURCE_PATH = Path("AgentPad/Services/AgentLocalModelProviderTransport.swift")
TEST_PATH = Path("AgentPadTests/AgentLocalModelProviderTransportTests.swift")

source = SOURCE_PATH.read_text(encoding="utf-8")
tests = TEST_PATH.read_text(encoding="utf-8")

helper_signature = "static func projectedInferenceMessages("
if helper_signature not in source:
    anchor = """    private static func validateDescriptor(\n"""
    if source.count(anchor) != 1:
        raise SystemExit(f"projection helper anchor drifted: {source.count(anchor)} matches")

    helper = '''    /// Produces the bounded message view used by the physical local model.\n    /// The full canonical transcript has already been parsed and validated before\n    /// this runs; omission therefore never weakens canonical/tool-history checks.\n    /// Leading instructions stay byte-identical for prompt-cache stability, the\n    /// active user/tool tail is never dropped, and older turns are admitted from\n    /// newest to oldest only while the conservative physical-context budget fits.\n    static func projectedInferenceMessages(\n        _ messages: [AgentLocalModelInferenceMessage],\n        maximumOutputTokens: UInt64,\n        contextWindowTokens: UInt64\n    ) throws -> [AgentLocalModelInferenceMessage] {\n        guard !messages.isEmpty,\n              contextWindowTokens > maximumOutputTokens else {\n            throw AgentLocalModelProviderTransportError.inputLimitExceeded\n        }\n        let promptBudget = contextWindowTokens - maximumOutputTokens\n\n        func fits(_ candidate: [AgentLocalModelInferenceMessage]) throws -> Bool {\n            try conservativeInputTokenUpperBound(for: candidate) <= promptBudget\n        }\n\n        if try fits(messages) {\n            return messages\n        }\n\n        guard let latestUserIndex = messages.lastIndex(where: { $0.role == .user }) else {\n            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope\n        }\n\n        var prefixCount = 0\n        while prefixCount < latestUserIndex {\n            switch messages[prefixCount].role {\n            case .system, .developer:\n                prefixCount += 1\n            case .user, .assistant:\n                break\n            }\n            if prefixCount < latestUserIndex {\n                let role = messages[prefixCount].role\n                if role != .system && role != .developer { break }\n            }\n        }\n\n        let stablePrefix = Array(messages.prefix(prefixCount))\n        let activeTail = Array(messages[latestUserIndex...])\n        let omissionReceipt = AgentLocalModelInferenceMessage(\n            role: .system,\n            content: "NovaForge local context projection: older canonical turns were omitted from this inference window after full validation. They remain authoritative in persisted history and Project Capsule/retrieval state. Continue from the retained recent context only."\n        )\n\n        var retainedMiddle: [AgentLocalModelInferenceMessage] = []\n        var projected = stablePrefix + [omissionReceipt] + activeTail\n        guard try fits(projected) else {\n            throw AgentLocalModelProviderTransportError.inputLimitExceeded\n        }\n\n        if prefixCount < latestUserIndex {\n            for index in stride(\n                from: latestUserIndex - 1,\n                through: prefixCount,\n                by: -1\n            ) {\n                let candidate = stablePrefix\n                    + [omissionReceipt]\n                    + [messages[index]]\n                    + retainedMiddle\n                    + activeTail\n                guard try fits(candidate) else { break }\n                retainedMiddle.insert(messages[index], at: 0)\n                projected = candidate\n            }\n        }\n\n        return projected\n    }\n\n'''
    source = source.replace(anchor, helper + anchor, 1)

old_budget = '''        let inputUpperBound = try conservativeInputTokenUpperBound(for: messages)\n        let reserved = inputUpperBound.addingReportingOverflow(maximumOutputTokens)\n        guard !reserved.overflow,\n              reserved.partialValue <= descriptor.route.capabilities.contextWindowTokens,\n              reserved.partialValue <= UInt64(variant.contextTokens)\n        else { throw AgentLocalModelProviderTransportError.inputLimitExceeded }\n'''
new_budget = '''        let physicalContextWindow = min(\n            descriptor.route.capabilities.contextWindowTokens,\n            UInt64(variant.contextTokens)\n        )\n        let projectedMessages = try projectedInferenceMessages(\n            messages,\n            maximumOutputTokens: maximumOutputTokens,\n            contextWindowTokens: physicalContextWindow\n        )\n        let inputUpperBound = try conservativeInputTokenUpperBound(\n            for: projectedMessages\n        )\n        let reserved = inputUpperBound.addingReportingOverflow(maximumOutputTokens)\n        guard !reserved.overflow,\n              reserved.partialValue <= physicalContextWindow\n        else { throw AgentLocalModelProviderTransportError.inputLimitExceeded }\n'''

if old_budget in source:
    if source.count(old_budget) != 1:
        raise SystemExit("context budget marker is not unique")
    source = source.replace(old_budget, new_budget, 1)
elif "let projectedMessages = try projectedInferenceMessages(" not in source:
    raise SystemExit("context budget marker drifted")

old_request_messages = '''                messages: messages,\n                temperature: temperature,\n'''
new_request_messages = '''                messages: projectedMessages,\n                temperature: temperature,\n'''
if old_request_messages in source:
    if source.count(old_request_messages) != 1:
        raise SystemExit("inference request message marker is not unique")
    source = source.replace(old_request_messages, new_request_messages, 1)
elif "messages: projectedMessages," not in source:
    raise SystemExit("inference request message marker drifted")

required_source = [
    helper_signature,
    "let projectedMessages = try projectedInferenceMessages(",
    "messages: projectedMessages,",
    "Project Capsule/retrieval state",
]
for needle in required_source:
    if source.count(needle) != 1:
        raise SystemExit(f"post-transform source validation failed for {needle!r}")

sentinel = "func testLocalInferenceProjectionBoundsLongHistoryAndPreservesActiveTail()"
if sentinel not in tests:
    tests += r'''

extension AgentLocalModelProviderTransportTests {
    func testLocalInferenceProjectionBoundsLongHistoryAndPreservesActiveTail() throws {
        let stableSystem = AgentLocalModelInferenceMessage(
            role: .system,
            content: "stable-system-v1"
        )
        let stableDeveloper = AgentLocalModelInferenceMessage(
            role: .developer,
            content: "stable-developer-v1"
        )
        var messages = [stableSystem, stableDeveloper]
        for index in 0..<12 {
            messages.append(.init(
                role: .user,
                content: "older-user-\(index)-" + String(repeating: "x", count: 90)
            ))
            messages.append(.init(
                role: .assistant,
                content: "older-assistant-\(index)-" + String(repeating: "y", count: 90)
            ))
        }
        let activeUser = AgentLocalModelInferenceMessage(
            role: .user,
            content: "ACTIVE USER REQUEST"
        )
        let activeToolSummary = AgentLocalModelInferenceMessage(
            role: .assistant,
            content: "ACTIVE TOOL RESULT"
        )
        messages.append(activeUser)
        messages.append(activeToolSummary)

        let projected = try AgentLocalModelProviderTransport.projectedInferenceMessages(
            messages,
            maximumOutputTokens: 64,
            contextWindowTokens: 640
        )

        XCTAssertLessThan(projected.count, messages.count)
        XCTAssertEqual(projected[0], stableSystem)
        XCTAssertEqual(projected[1], stableDeveloper)
        XCTAssertTrue(projected.contains(where: {
            $0.content.contains("older canonical turns were omitted")
        }))
        XCTAssertEqual(Array(projected.suffix(2)), [activeUser, activeToolSummary])
        XCTAssertLessThanOrEqual(
            try AgentLocalModelProviderTransport.conservativeInputTokenUpperBound(
                for: projected
            ) + 64,
            640
        )
    }

    func testLocalInferenceProjectionIsDeterministic() throws {
        var messages: [AgentLocalModelInferenceMessage] = [
            .init(role: .system, content: "stable"),
        ]
        for index in 0..<16 {
            messages.append(.init(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "history-\(index)-" + String(repeating: "z", count: 72)
            ))
        }
        messages.append(.init(role: .user, content: "latest"))

        let first = try AgentLocalModelProviderTransport.projectedInferenceMessages(
            messages,
            maximumOutputTokens: 48,
            contextWindowTokens: 512
        )
        let second = try AgentLocalModelProviderTransport.projectedInferenceMessages(
            messages,
            maximumOutputTokens: 48,
            contextWindowTokens: 512
        )
        XCTAssertEqual(first, second)
    }

    func testLocalInferenceProjectionFailsRatherThanTruncatingActiveTail() {
        let messages: [AgentLocalModelInferenceMessage] = [
            .init(role: .system, content: "stable"),
            .init(
                role: .user,
                content: "active-" + String(repeating: "q", count: 2_000)
            ),
        ]

        XCTAssertThrowsError(
            try AgentLocalModelProviderTransport.projectedInferenceMessages(
                messages,
                maximumOutputTokens: 64,
                contextWindowTokens: 256
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentLocalModelProviderTransportError,
                .inputLimitExceeded
            )
        }
    }
}
'''

SOURCE_PATH.write_text(source, encoding="utf-8")
TEST_PATH.write_text(tests, encoding="utf-8")
print(f"patched {SOURCE_PATH} and {TEST_PATH}")
