#!/usr/bin/env python3
from pathlib import Path

path = Path('AgentPadTests/AgentRuntimeLifecycleTests.swift')
text = path.read_text()
marker = 'final class Qwen38StrictTargetTests: XCTestCase'
if marker in text:
    print('PASS: strict target tests already present')
    raise SystemExit(0)

addition = r'''

// MARK: - Qwen 3.8 27B strict local target contract

@MainActor
final class Qwen38StrictTargetTests: XCTestCase {
    func testDefaultAndPresentationNeverFallBackFromQwen38() {
        let expected = LocalModelCatalog.exactQwen38Variant?.id
            ?? Qwen38ReleaseDiscovery.unavailableModelID

        XCTAssertEqual(LocalModelCatalog.defaultVariant.id, expected)
        XCTAssertEqual(LocalModelCatalog.presentationOrder.map(\.id), [expected])

        for variant in LocalModelCatalog.presentationOrder {
            let isWaitingSentinel = variant.id == Qwen38ReleaseDiscovery.unavailableModelID
            XCTAssertTrue(
                isWaitingSentinel || LocalModelCatalog.isExactQwen38Target(variant),
                "Local presentation must never substitute a non-Qwen-3.8-27B model"
            )
        }
    }

    func testLegacyLocalModelIDsDoNotResolveInStrictBuild() {
        XCTAssertNil(
            LocalModelCatalog.variant(
                for: "Qwen/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M"
            )
        )
        XCTAssertNil(LocalModelCatalog.variant(for: "qwen3.6-27b"))
        XCTAssertNil(LocalModelCatalog.variant(for: "qwen3.5-27b"))
        XCTAssertNotNil(
            LocalModelCatalog.variant(
                for: Qwen38ReleaseDiscovery.unavailableModelID
            )
        )
    }

    func testUnavailableSentinelIsNonRunnableAndExplainsWhy() {
        let sentinel = Qwen38ReleaseDiscovery.unavailableVariant
        XCTAssertEqual(sentinel.id, Qwen38ReleaseDiscovery.unavailableModelID)
        XCTAssertEqual(sentinel.expectedBytes, 0)
        XCTAssertFalse(sentinel.useGPU)
        XCTAssertEqual(sentinel.gpuLayerCount, 0)

        let message = LocalModelCatalog.compatibilityMessage(for: sentinel)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Qwen 3.8 27B") == true)
        XCTAssertTrue(message?.contains("will not substitute another model") == true)
    }
}
'''

path.write_text(text.rstrip() + addition + '\n')
print('PASS: staged strict Qwen 3.8 target regression tests')
