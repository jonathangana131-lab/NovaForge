import XCTest
@testable import SwiftLlama

final class NovaForgeMLXRuntimeTests: XCTestCase {
    func testA14BalancedProfileUsesNanbeigeThreeBitAndTurboQuant() {
        let profile = NovaForgeMLXProfile.nanbeige42Coder3Bit

        XCTAssertEqual(
            profile.repositoryID,
            "MercuriusDream/Nanbeige4.2-3B-mlx-3bit"
        )
        XCTAssertEqual(profile.kvScheme, "turbo8v3")
        XCTAssertEqual(profile.maximumKVSize, 2_048)
        XCTAssertEqual(profile.maximumNewTokens, 384)
        XCTAssertGreaterThan(profile.approximateWeightBytes, 1_700_000_000)
        XCTAssertLessThan(profile.approximateWeightBytes, 1_900_000_000)
    }

    func testA14FallbackProfileReducesWeightFootprint() {
        let balanced = NovaForgeMLXProfile.nanbeige42Coder3Bit
        let fallback = NovaForgeMLXProfile.nanbeige42Coder2Bit

        XCTAssertEqual(
            fallback.repositoryID,
            "MercuriusDream/Nanbeige4.2-3B-mlx-2bit"
        )
        XCTAssertLessThan(
            fallback.approximateWeightBytes,
            balanced.approximateWeightBytes
        )
        XCTAssertLessThanOrEqual(
            fallback.maximumNewTokens,
            balanced.maximumNewTokens
        )
    }

    func testGenerationOptionsStayCodingBiasedByDefault() {
        let options = NovaForgeMLXGenerationOptions()

        XCTAssertEqual(options.maximumTokens, 320)
        XCTAssertEqual(options.temperature, 0.15, accuracy: 0.0001)
        XCTAssertEqual(options.topP, 0.95, accuracy: 0.0001)
    }

    func testGenerationLeaseRejectsWarmAndUnloadUntilGenerationEnds() throws {
        var gate = NovaForgeMLXRuntimeOperationGate()
        try gate.begin(.generation)

        XCTAssertTrue(gate.isGenerating)
        XCTAssertThrowsError(try gate.begin(.warm)) { error in
            XCTAssertEqual(error as? NovaForgeMLXRuntimeError, .runtimeBusy)
        }
        XCTAssertThrowsError(try gate.requireIdle()) { error in
            XCTAssertEqual(error as? NovaForgeMLXRuntimeError, .runtimeBusy)
        }

        gate.end(.generation)
        XCTAssertFalse(gate.isGenerating)
        XCTAssertNoThrow(try gate.requireIdle())
    }

    func testWarmLeaseRejectsGenerationUntilWarmEnds() throws {
        var gate = NovaForgeMLXRuntimeOperationGate()
        try gate.begin(.warm)

        XCTAssertFalse(gate.isGenerating)
        XCTAssertThrowsError(try gate.begin(.generation)) { error in
            XCTAssertEqual(error as? NovaForgeMLXRuntimeError, .runtimeBusy)
        }
        XCTAssertThrowsError(try gate.begin(.warm)) { error in
            XCTAssertEqual(error as? NovaForgeMLXRuntimeError, .runtimeBusy)
        }

        gate.end(.warm)
        XCTAssertNoThrow(try gate.begin(.generation))
        gate.end(.generation)
    }

    func testDuplicateGenerationKeepsSpecificAlreadyInProgressError() throws {
        var gate = NovaForgeMLXRuntimeOperationGate()
        try gate.begin(.generation)

        XCTAssertThrowsError(try gate.begin(.generation)) { error in
            XCTAssertEqual(
                error as? NovaForgeMLXRuntimeError,
                .generationAlreadyInProgress
            )
        }

        gate.end(.generation)
    }
}
