#!/usr/bin/env python3
"""Repair only the Qwen-3.8 static catalog qualification assertion.

The product is allowed to say older models are *not* substitutes. The test must
reject an older model identity/qualification claim, not the explanatory words
"Qwen 3.6" or "Qwen 3.5" inside a no-fallback sentence.
"""
from pathlib import Path

PATH = Path("AgentPadTests/AgentLocalModelProviderTransportTests.swift")
source = PATH.read_text(encoding="utf-8")

old = '''    func testStaticCatalogDoesNotSelfAwardDeviceQualification() {\n        let target = LocalModelCatalog.defaultVariant\n        XCTAssertEqual(LocalModelCatalog.all.count, 1)\n        XCTAssertEqual(LocalModelCatalog.presentationOrder.count, 1)\n        XCTAssertEqual(LocalModelCatalog.all.first?.id, target.id)\n        XCTAssertFalse(target.isIPhone12SafeDefault)\n        XCTAssertEqual(target.deviceFit, .extreme)\n        XCTAssertTrue(target.parameterLabel.localizedCaseInsensitiveContains("27B"))\n        XCTAssertTrue(\n            [target.id, target.displayName, target.details]\n                .joined(separator: " ")\n                .localizedCaseInsensitiveContains("3.8")\n        )\n\n        let forbiddenStaticClaims = [\n            "Device proven",\n            "physical-device canary proven",\n            "The proven iPhone 12 default",\n            "Qwen 3.6",\n            "Qwen3.6",\n            "Qwen 3.5",\n            "Qwen3.5",\n        ]\n        let staticPresentation = [\n            target.deviceFit.title,\n            target.benchmarkSummary,\n            target.details,\n        ].joined(separator: " ")\n        for claim in forbiddenStaticClaims {\n            XCTAssertFalse(\n                staticPresentation.localizedCaseInsensitiveContains(claim),\n                "Qwen 3.8 product metadata must not contain forbidden claim: \\(claim)"\n            )\n        }\n    }\n'''

new = '''    func testStaticCatalogDoesNotSelfAwardDeviceQualification() {\n        let target = LocalModelCatalog.defaultVariant\n        XCTAssertEqual(LocalModelCatalog.all.count, 1)\n        XCTAssertEqual(LocalModelCatalog.presentationOrder.count, 1)\n        XCTAssertEqual(LocalModelCatalog.all.first?.id, target.id)\n        XCTAssertFalse(target.isIPhone12SafeDefault)\n        XCTAssertEqual(target.deviceFit, .extreme)\n        XCTAssertTrue(target.parameterLabel.localizedCaseInsensitiveContains("27B"))\n\n        let identity = [\n            target.id, target.displayName, target.shortName, target.parameterLabel,\n        ].joined(separator: " ")\n        XCTAssertTrue(identity.localizedCaseInsensitiveContains("3.8"))\n        XCTAssertTrue(identity.localizedCaseInsensitiveContains("27B"))\n        XCTAssertFalse(identity.localizedCaseInsensitiveContains("3.6"))\n        XCTAssertFalse(identity.localizedCaseInsensitiveContains("3.5"))\n\n        // Product copy may explicitly explain that older models are NOT\n        // substitutes. Reject false qualification claims, not that explanation.\n        let forbiddenQualificationClaims = [\n            "Device proven",\n            "physical-device canary proven",\n            "The proven iPhone 12 default",\n        ]\n        let staticPresentation = [\n            target.deviceFit.title,\n            target.benchmarkSummary,\n            target.details,\n        ].joined(separator: " ")\n        for claim in forbiddenQualificationClaims {\n            XCTAssertFalse(\n                staticPresentation.localizedCaseInsensitiveContains(claim),\n                "Qwen 3.8 product metadata must not self-award qualification: \\(claim)"\n            )\n        }\n    }\n'''

if old in source:
    if source.count(old) != 1:
        raise SystemExit("static catalog assertion marker is ambiguous")
    source = source.replace(old, new, 1)
    PATH.write_text(source, encoding="utf-8")
    print(f"patched {PATH}")
elif new in source:
    print(f"already patched {PATH}")
else:
    raise SystemExit("static catalog assertion marker drifted")

updated = PATH.read_text(encoding="utf-8")
if updated.count("func testStaticCatalogDoesNotSelfAwardDeviceQualification()") != 1:
    raise SystemExit("test function count changed unexpectedly")
