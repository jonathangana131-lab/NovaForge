import XCTest
@testable import ForgeQualityCore

final class ForgeQualityCoreTests: XCTestCase {}

extension ForgeQualityCoreTests {
    func id(_ value: String) -> ForgeQualityID {
        try! ForgeQualityID(value)
    }

    func measurementProtocol(revision: UInt64 = 7) -> ForgeQualityMeasurementProtocolIdentity {
        try! ForgeQualityMeasurementProtocolIdentity(
            protocolID: id("quality-protocol"),
            revision: revision
        )
    }

    func journeyScope(
        id journeyID: String = "journey-1",
        definitionDigest: String = "journey-definition-v1"
    ) -> ForgeQualityScope {
        .journey(
            id: id(journeyID),
            definitionDigest: id(definitionDigest)
        )
    }

    func completionTarget() throws -> ForgeQualityCompletionTarget {
        try ForgeQualityCompletionTarget(
            missionID: id("mission-1"),
            projectID: id("project-1"),
            sourceRevision: id("source-1"),
            constitutionRevision: 4,
            constitutionReceiptID: id("constitution-receipt-4")
        )
    }

    func policy(
        targets: [ForgeQualityTarget],
        completionTarget acceptedTarget: ForgeQualityCompletionTarget? = nil,
        protocolIdentity: ForgeQualityMeasurementProtocolIdentity? = nil
    ) throws -> ForgeQualityPolicy {
        try ForgeQualityPolicy(
            policyID: id("quality-policy"),
            policyRevision: 3,
            policyAuthorityReceiptID: id("quality-authority"),
            criterionID: id("quality-criterion"),
            completionTarget: acceptedTarget ?? completionTarget(),
            checkpointID: id("checkpoint-7"),
            measurementProtocol: protocolIdentity ?? measurementProtocol(),
            targets: targets
        )
    }

    func trustedPolicy(
        targets: [ForgeQualityTarget],
        completionTarget acceptedTarget: ForgeQualityCompletionTarget? = nil,
        protocolIdentity: ForgeQualityMeasurementProtocolIdentity? = nil
    ) -> ForgeQualityTrustedPolicy {
        ForgeQualityTrustedPolicy(
            authenticatedPolicy: try! policy(
                targets: targets,
                completionTarget: acceptedTarget,
                protocolIdentity: protocolIdentity
            )
        )
    }

    func runBinding(
        runID: String = "run-1",
        environmentKind: ForgeQualityEnvironmentKind = .physicalDevice,
        osBuild: String = "ios-build-27A1"
    ) -> ForgeQualityRunBinding {
        ForgeQualityRunBinding(
            projectID: id("project-1"),
            sourceRevision: id("source-1"),
            checkpointID: id("checkpoint-7"),
            runtimeRevision: id("runtime-9"),
            hostAppBuildID: id("novaforge-build-42"),
            runID: id(runID),
            environmentKind: environmentKind,
            deviceProfileID: id("iPhone13,2"),
            osBuild: id(osBuild)
        )
    }

    func trustedRunBinding(
        _ binding: ForgeQualityRunBinding? = nil,
        completionTarget acceptedTarget: ForgeQualityCompletionTarget? = nil
    ) -> ForgeQualityTrustedRunBinding {
        ForgeQualityTrustedRunBinding(
            authenticatedBinding: binding ?? runBinding(),
            authenticatedCompletionTarget: acceptedTarget ?? (try! completionTarget())
        )
    }

    func measurement(
        measurementID explicitMeasurementID: String? = nil,
        binding: ForgeQualityRunBinding? = nil,
        protocolIdentity: ForgeQualityMeasurementProtocolIdentity? = nil,
        metric: ForgeQualityMetric,
        scope: ForgeQualityScope = .run,
        value: Double,
        samples: Int = 1,
        receipt: String
    ) throws -> ForgeQualityMeasurement {
        let evidenceKind = metric.expectedEvidenceKind
        return try ForgeQualityMeasurement(
            measurementID: id(explicitMeasurementID ?? "measurement-\(receipt)"),
            producerReceiptID: id(receipt),
            binding: binding ?? runBinding(),
            measurementProtocol: protocolIdentity ?? measurementProtocol(),
            metric: metric,
            scope: scope,
            evidenceKind: evidenceKind,
            value: value,
            sampleCount: samples
        )
    }

    func batch(_ measurements: [ForgeQualityMeasurement]) throws -> ForgeQualityMeasurementBatch {
        try ForgeQualityMeasurementBatch(measurements: measurements)
    }

    func trustedBatch(_ measurements: [ForgeQualityMeasurement]) -> ForgeQualityTrustedMeasurementBatch {
        ForgeQualityTrustedMeasurementBatch(
            authenticatedBatch: try! ForgeQualityMeasurementBatch(measurements: measurements)
        )
    }

    func trustedBatch(_ measurement: ForgeQualityMeasurement) -> ForgeQualityTrustedMeasurementBatch {
        trustedBatch([measurement])
    }

    func trusted(_ measurement: ForgeQualityMeasurement) -> ForgeQualityTrustedMeasurement {
        ForgeQualityTrustedMeasurement(authenticatedMeasurement: measurement)
    }
}
