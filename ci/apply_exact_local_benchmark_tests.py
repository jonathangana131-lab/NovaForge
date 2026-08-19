#!/usr/bin/env python3
from pathlib import Path

path = Path("AgentPadTests/AgentLocalModelProviderTransportTests.swift")
source = path.read_text(encoding="utf-8")
sentinel = "func testLocalModelBenchmarkPrefersExactTokenTelemetry()"

if sentinel not in source:
    source += r'''

extension AgentLocalModelProviderTransportTests {
    func testLocalModelBenchmarkPrefersExactTokenTelemetry() {
        let result = LocalModelBenchmarkResult(
            modelName: "Qwen 27B Extreme",
            timeToFirstToken: 1.2,
            totalDuration: 5.0,
            generatedCharacters: 999,
            prefillDuration: 0.9,
            decodeDuration: 3.7,
            generatedTokens: 44,
            exactTokensPerSecond: 11.89,
            runtimeProfile: "Extreme storage-backed profile"
        )

        XCTAssertTrue(result.hasExactTokenTelemetry)
        XCTAssertEqual(result.displayedTokenCount, 44)
        XCTAssertEqual(result.tokensPerSecond, 11.89, accuracy: 0.0001)
        XCTAssertEqual(result.prefillDuration, 0.9)
        XCTAssertEqual(result.decodeDuration, 3.7)
        XCTAssertEqual(result.runtimeProfile, "Extreme storage-backed profile")
    }

    func testLocalModelBenchmarkLabelsEstimatedFallbackWithoutRuntimeTelemetry() {
        let result = LocalModelBenchmarkResult(
            modelName: "Fallback",
            timeToFirstToken: 1.0,
            totalDuration: 2.0,
            generatedCharacters: 38
        )

        XCTAssertFalse(result.hasExactTokenTelemetry)
        XCTAssertEqual(result.estimatedTokens, 10)
        XCTAssertEqual(result.displayedTokenCount, 10)
        XCTAssertEqual(result.tokensPerSecond, 10.0, accuracy: 0.0001)
        XCTAssertNil(result.prefillDuration)
        XCTAssertNil(result.generatedTokens)
        XCTAssertNil(result.runtimeProfile)
    }

    func testLocalModelBenchmarkClampsInvalidNegativeMeasurements() {
        let result = LocalModelBenchmarkResult(
            modelName: "Clamp",
            timeToFirstToken: -1,
            totalDuration: -2,
            generatedCharacters: -3,
            prefillDuration: -4,
            decodeDuration: -5,
            generatedTokens: -6,
            exactTokensPerSecond: -7,
            runtimeProfile: "test"
        )

        XCTAssertEqual(result.timeToFirstToken, 0)
        XCTAssertEqual(result.totalDuration, 0)
        XCTAssertEqual(result.generatedCharacters, 0)
        XCTAssertEqual(result.prefillDuration, 0)
        XCTAssertEqual(result.decodeDuration, 0)
        XCTAssertEqual(result.generatedTokens, 0)
        XCTAssertEqual(result.exactTokensPerSecond, 0)
        XCTAssertTrue(result.hasExactTokenTelemetry)
    }
}
'''

if source.count(sentinel) != 1:
    raise SystemExit(f"benchmark telemetry test sentinel count={source.count(sentinel)}")

path.write_text(source, encoding="utf-8")
print(f"patched {path}")
