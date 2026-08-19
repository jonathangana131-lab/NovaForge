#!/usr/bin/env python3
"""Fix Q1_0_G128 release detection without changing quant preference.

Q1_0 is a textual prefix of Q1_0_G128. The release watcher must therefore
match the more-specific marker first even though generic Q1_0 remains the
preferred quant rank. The transform is fail-closed and idempotent.
"""
from pathlib import Path

runtime_path = Path("AgentPad/Services/LocalModelRuntime.swift")
runtime = runtime_path.read_text()

old_signature = "    private static func quantization(from filename: String) -> String {\n"
new_signature = "    static func quantization(from filename: String) -> String {\n"
if old_signature in runtime:
    if runtime.count(old_signature) != 1:
        raise SystemExit("expected exactly one private quantization detector")
    runtime = runtime.replace(old_signature, new_signature, 1)
elif new_signature not in runtime:
    raise SystemExit("Qwen 3.8 quantization detector signature not found")

old_markers = '''        for marker in [
            "Q1_0", "Q1_0_G128", "IQ1_S", "TQ1_0", "IQ1_M",
            "TQ2_0", "Q2_0", "UD-IQ2_XXS", "IQ2_XXS", "IQ2_XS",
            "Q2_K_XS", "Q2_K", "Q3_K_XS", "Q3_K_S", "Q3_K_M", "Q4_K_M"
        ] where upper.contains(marker) {
'''
new_markers = '''        // Match the specific G128 filename marker before generic Q1_0:
        // `Q1_0_G128` contains `Q1_0`, so generic-first silently erases the
        // format distinction used by release identity and runtime policy.
        for marker in [
            "Q1_0_G128", "Q1_0", "IQ1_S", "TQ1_0", "IQ1_M",
            "TQ2_0", "Q2_0", "UD-IQ2_XXS", "IQ2_XXS", "IQ2_XS",
            "Q2_K_XS", "Q2_K", "Q3_K_XS", "Q3_K_S", "Q3_K_M", "Q4_K_M"
        ] where upper.contains(marker) {
'''
if old_markers in runtime:
    if runtime.count(old_markers) != 1:
        raise SystemExit("expected exactly one generic-first release detector")
    runtime = runtime.replace(old_markers, new_markers, 1)
elif new_markers not in runtime:
    raise SystemExit("Qwen 3.8 quantization marker list not found")

# Keep ranking intentionally independent from lexical detection. Generic Q1_0
# remains preferred, while G128 remains distinguishable when it is discovered.
rank_anchor = '''        case "Q1_0": 0
        case "Q1_0_G128": 1
'''
if rank_anchor not in runtime:
    raise SystemExit("Q1 quant preference order drifted unexpectedly")

runtime_path.write_text(runtime)

test_path = Path("AgentPadTests/AgentLocalModelProviderTransportTests.swift")
tests = test_path.read_text()
test_name = "testQwen38QuantizationDetectionPrefersSpecificQ1G128Marker"
new_test = '''

extension AgentLocalModelProviderTransportTests {
    func testQwen38QuantizationDetectionPrefersSpecificQ1G128Marker() {
        XCTAssertEqual(
            Qwen38ReleaseDiscovery.quantization(
                from: "Qwen3.8-27B-Q1_0_G128.gguf"
            ),
            "Q1_0_G128"
        )
        XCTAssertEqual(
            Qwen38ReleaseDiscovery.quantization(
                from: "Qwen3.8-27B-Q1_0.gguf"
            ),
            "Q1_0"
        )
    }
}
'''
anchor = '''

extension AgentLocalModelProviderTransportTests {
    func testLocalModelBenchmarkPrefersExactTokenTelemetry() {
'''
if test_name not in tests:
    if tests.count(anchor) != 1:
        raise SystemExit("benchmark-test insertion anchor drifted unexpectedly")
    tests = tests.replace(anchor, new_test + anchor, 1)
test_path.write_text(tests)

# Fail closed if the transform itself ever regresses.
updated = runtime_path.read_text()
detector = updated.split(new_signature, 1)[1].split("    private static func runtimeSupports", 1)[0]
if detector.index('"Q1_0_G128"') > detector.index('"Q1_0"'):
    raise SystemExit("Q1_0_G128 must be detected before Q1_0")
if test_name not in test_path.read_text():
    raise SystemExit("Q1_0_G128 regression test was not installed")

print("PASS: Q1_0_G128 release detection remains specific-before-generic")
