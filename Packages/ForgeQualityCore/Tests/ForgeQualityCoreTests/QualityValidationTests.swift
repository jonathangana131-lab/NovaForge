import Foundation
import XCTest
@testable import ForgeQualityCore

extension ForgeQualityCoreTests {
    func testCanonicalIdentifierRejectsWhitespaceAndControlCharacters() throws {
        XCTAssertThrowsError(try ForgeQualityID(" run"))
        XCTAssertThrowsError(try ForgeQualityID("run\n1"))
        XCTAssertEqual(try ForgeQualityID("run 1").rawValue, "run 1")
    }

    func testCompletionTargetRejectsZeroRevisionAndDecodeRevalidates() throws {
        XCTAssertThrowsError(
            try ForgeQualityCompletionTarget(
                missionID: id("mission"), projectID: id("project"), sourceRevision: id("source"),
                constitutionRevision: 0, constitutionReceiptID: id("constitution-receipt")
            )
        )

        let json = """
        {"missionID":"mission","projectID":"project","sourceRevision":"source","constitutionRevision":0,"constitutionReceiptID":"constitution-receipt"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeQualityCompletionTarget.self, from: json))
    }

    func testMeasurementProtocolRejectsZeroRevisionAndDecodeRevalidates() throws {
        XCTAssertThrowsError(
            try ForgeQualityMeasurementProtocolIdentity(
                protocolID: id("quality-protocol"),
                revision: 0
            )
        )

        let json = """
        {"protocolID":"quality-protocol","revision":0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForgeQualityMeasurementProtocolIdentity.self,
                from: json
            )
        )
    }

    func testMetricDirectionIsExplicit() throws {
        XCTAssertNoThrow(
            try ForgeQualityTarget(
                metric: .sustainedFramesPerSecond,
                comparator: .atLeast,
                threshold: 50
            )
        )
        XCTAssertThrowsError(
            try ForgeQualityTarget(
                metric: .sustainedFramesPerSecond,
                comparator: .atMost,
                threshold: 50
            )
        )
        XCTAssertThrowsError(
            try ForgeQualityTarget(
                metric: .p95FrameTimeMilliseconds,
                comparator: .atLeast,
                threshold: 20
            )
        )
    }

    func testMetricValueDomainsFailClosed() throws {
        XCTAssertThrowsError(
            try ForgeQualityTarget(metric: .longFrameRatePercent, comparator: .atMost, threshold: 101)
        )
        XCTAssertThrowsError(
            try measurement(metric: .fatalRuntimeErrorCount, value: 1.5, receipt: "fatal")
        )
        XCTAssertThrowsError(
            try measurement(metric: .p95FrameTimeMilliseconds, value: .infinity, receipt: "frame")
        )
    }

    func testTargetRejectsInvalidMinimumSampleCount() throws {
        XCTAssertThrowsError(
            try ForgeQualityTarget(
                metric: .p95FrameTimeMilliseconds,
                comparator: .atMost,
                threshold: 20,
                minimumSampleCount: 0
            )
        )
    }

    func testPolicyRejectsDuplicateMetricScopeAndUnknownSchema() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        XCTAssertThrowsError(try policy(targets: [target, target]))

        let valid = try policy(targets: [target])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        object["schemaVersion"] = ForgeQualityPolicy.currentSchemaVersion + 1
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeQualityPolicy.self, from: data))
    }

    func testPolicyDecodeRevalidatesNestedThreshold() throws {
        let target = try ForgeQualityTarget(
            metric: .longFrameRatePercent,
            comparator: .atMost,
            threshold: 10
        )
        let valid = try policy(targets: [target])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        var targets = try XCTUnwrap(object["targets"] as? [[String: Any]])
        targets[0]["threshold"] = 150
        object["targets"] = targets
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeQualityPolicy.self, from: data))
    }

    func testMeasurementRequiresMetricEvidenceKind() throws {
        XCTAssertThrowsError(
            try ForgeQualityMeasurement(
                measurementID: id("m"),
                producerReceiptID: id("r"),
                binding: runBinding(),
                measurementProtocol: measurementProtocol(),
                metric: .accessibilityCriticalViolationCount,
                evidenceKind: .runtimeTelemetry,
                value: 0,
                sampleCount: 1
            )
        )
    }
}
