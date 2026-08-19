#!/usr/bin/env python3
"""Align local transport canonical-history admission with the canonical authority.

The physical llama window remains model-sized and is handled by context projection.
This transform only removes the stale 64-message pre-projection bottleneck while
keeping the same 512-message / 8 MiB / 1 MiB text ceilings as
AgentCanonicalContextLimits.production.
"""
from pathlib import Path

SOURCE_PATH = Path("AgentPad/Services/AgentLocalModelProviderTransport.swift")
TEST_PATH = Path("AgentPadTests/AgentLocalModelProviderTransportTests.swift")
source = SOURCE_PATH.read_text(encoding="utf-8")
tests = TEST_PATH.read_text(encoding="utf-8")

old_limits = '''    private static let requestPath = "/v1/local/chat/completions"\n    private static let maximumMessages = 64\n    private static let maximumBufferedFrames = 128\n'''
new_limits = '''    private static let requestPath = "/v1/local/chat/completions"\n    // Canonical-history admission follows the same authority that prepares\n    // provider turns. The much smaller physical llama window is enforced only\n    // after full validation by projectedInferenceMessages(_:...).\n    static let maximumMessages = AgentCanonicalContextLimits.production.maximumProviderMessages\n    static let maximumRequestUTF8Bytes = AgentCanonicalContextLimits.production.maximumRequestUTF8Bytes\n    static let maximumTextPartUTF8Bytes = AgentCanonicalContextLimits.production.maximumTextPartUTF8Bytes\n    private static let maximumBufferedFrames = 128\n'''
if old_limits in source:
    if source.count(old_limits) != 1:
        raise SystemExit("transport limit marker is not unique")
    source = source.replace(old_limits, new_limits, 1)
elif "AgentCanonicalContextLimits.production.maximumProviderMessages" not in source:
    raise SystemExit("transport limit marker drifted")

parse_anchor = '''        guard request.method == .post,\n              request.relativePath == requestPath,\n              request.relativePath == descriptor.requestPath,\n              case let .object(body) = request.body\n        else { throw AgentLocalModelProviderTransportError.invalidRequestEnvelope }\n\n        let requiredKeys: Set<String> = [\n'''
parse_replacement = '''        guard request.method == .post,\n              request.relativePath == requestPath,\n              request.relativePath == descriptor.requestPath,\n              case let .object(body) = request.body\n        else { throw AgentLocalModelProviderTransportError.invalidRequestEnvelope }\n\n        // Re-bind the encoded request body to the canonical authority's total\n        // byte ceiling before parsing nested text/tool payloads. This prevents\n        // the higher history-count ceiling from becoming an allocation/DoS path.\n        let encodedBody: Data\n        do {\n            encodedBody = try JSONEncoder().encode(JSONValue.object(body))\n        } catch {\n            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope\n        }\n        guard encodedBody.count <= maximumRequestUTF8Bytes else {\n            throw AgentLocalModelProviderTransportError.inputLimitExceeded\n        }\n\n        let requiredKeys: Set<String> = [\n'''
if parse_anchor in source:
    if source.count(parse_anchor) != 1:
        raise SystemExit("parse request-budget anchor is not unique")
    source = source.replace(parse_anchor, parse_replacement, 1)
elif "encodedBody.count <= maximumRequestUTF8Bytes" not in source:
    raise SystemExit("parse request-budget anchor drifted")

text_guard = '''        guard !content.isEmpty else {\n            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope\n        }\n        return content\n'''
text_guard_replacement = '''        guard !content.isEmpty else {\n            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope\n        }\n        guard content.utf8.count <= maximumTextPartUTF8Bytes else {\n            throw AgentLocalModelProviderTransportError.inputLimitExceeded\n        }\n        return content\n'''
if text_guard in source:
    if source.count(text_guard) != 1:
        raise SystemExit(f"plain-text content guard is not unique: {source.count(text_guard)}")
    source = source.replace(text_guard, text_guard_replacement, 1)
elif "content.utf8.count <= maximumTextPartUTF8Bytes" not in source:
    raise SystemExit("plain-text content guard drifted")

required_source = [
    "AgentCanonicalContextLimits.production.maximumProviderMessages",
    "AgentCanonicalContextLimits.production.maximumRequestUTF8Bytes",
    "AgentCanonicalContextLimits.production.maximumTextPartUTF8Bytes",
    "encodedBody.count <= maximumRequestUTF8Bytes",
    "content.utf8.count <= maximumTextPartUTF8Bytes",
]
for needle in required_source:
    if source.count(needle) != 1:
        raise SystemExit(f"post-transform source validation failed for {needle!r}: {source.count(needle)}")

test_sentinel = "func testLocalCanonicalAdmissionMatchesCanonicalAuthorityLimits()"
if test_sentinel not in tests:
    tests += r'''

extension AgentLocalModelProviderTransportTests {
    func testLocalCanonicalAdmissionMatchesCanonicalAuthorityLimits() {
        XCTAssertEqual(
            AgentLocalModelProviderTransport.maximumMessages,
            AgentCanonicalContextLimits.production.maximumProviderMessages
        )
        XCTAssertEqual(AgentLocalModelProviderTransport.maximumMessages, 512)
        XCTAssertEqual(
            AgentLocalModelProviderTransport.maximumRequestUTF8Bytes,
            8 * 1_024 * 1_024
        )
        XCTAssertEqual(
            AgentLocalModelProviderTransport.maximumTextPartUTF8Bytes,
            1 * 1_024 * 1_024
        )
    }

    func testProjectionHandlesHistoryBeyondFormerSixtyFourMessageCeiling() throws {
        var messages: [AgentLocalModelInferenceMessage] = [
            .init(role: .system, content: "stable-system"),
            .init(role: .developer, content: "stable-developer"),
        ]
        for index in 0..<80 {
            messages.append(.init(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "history-\(index)-" + String(repeating: "h", count: 32)
            ))
        }
        messages.append(.init(role: .user, content: "LATEST USER"))

        XCTAssertGreaterThan(messages.count, 64)
        XCTAssertLessThan(messages.count, AgentLocalModelProviderTransport.maximumMessages)

        let projected = try AgentLocalModelProviderTransport.projectedInferenceMessages(
            messages,
            maximumOutputTokens: 64,
            contextWindowTokens: 768
        )
        XCTAssertLessThan(projected.count, messages.count)
        XCTAssertEqual(projected.first?.content, "stable-system")
        XCTAssertEqual(projected.last?.content, "LATEST USER")
        XCTAssertLessThanOrEqual(
            try AgentLocalModelProviderTransport.conservativeInputTokenUpperBound(
                for: projected
            ) + 64,
            768
        )
    }
}
'''

SOURCE_PATH.write_text(source, encoding="utf-8")
TEST_PATH.write_text(tests, encoding="utf-8")
print(f"patched {SOURCE_PATH} and {TEST_PATH}")
