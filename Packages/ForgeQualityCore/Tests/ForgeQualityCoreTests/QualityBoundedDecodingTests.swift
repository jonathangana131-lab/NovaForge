import Foundation
import XCTest
@testable import ForgeQualityCore

extension ForgeQualityCoreTests {
    func testPolicyDecodeRejectsOversizedTargetArrayAtPublicBound() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let candidate = try policy(targets: [target])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any]
        )
        let targetObject = try XCTUnwrap(
            (object["targets"] as? [[String: Any]])?.first
        )
        object["targets"] = Array(
            repeating: targetObject,
            count: ForgeQualityPolicy.maximumTargets + 1
        )
        let oversized = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(ForgeQualityPolicy.self, from: oversized)
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .tooManyTargets)
        }
    }

    func testMeasurementBatchDecodeRejectsOversizedArrayAtPublicBound() throws {
        let binding = runBinding()
        let protocolIdentity = measurementProtocol()
        let candidateMeasurement = try ForgeQualityMeasurement(
            measurementID: id("bounded-measurement"),
            producerReceiptID: id("bounded-producer"),
            binding: binding,
            measurementProtocol: protocolIdentity,
            metric: .p95FrameTimeMilliseconds,
            evidenceKind: .runtimeTelemetry,
            value: 16,
            sampleCount: 100
        )
        let candidate = try ForgeQualityMeasurementBatch(
            batchReceiptID: id("bounded-batch"),
            binding: binding,
            measurementProtocol: protocolIdentity,
            measurements: [candidateMeasurement]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any]
        )
        let measurementObject = try XCTUnwrap(
            (object["measurements"] as? [[String: Any]])?.first
        )
        object["measurements"] = Array(
            repeating: measurementObject,
            count: ForgeQualityMeasurementBatch.maximumMeasurements + 1
        )
        let oversized = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(ForgeQualityMeasurementBatch.self, from: oversized)
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .tooManyMeasurements)
        }
    }
}
