import Foundation
import Testing
@testable import ForgeQualityCore

struct ForgeQualityCoreTests {
    private func id(_ value: String) -> ForgeQualityID {
        try! ForgeQualityID(value)
    }

    private func binding(
        sourceRevision: String = "source-r2",
        runtimeRevision: String = "runtime-r7",
        runID: String = "run-1",
        environmentKind: ForgeQualityEnvironmentKind = .simulator
    ) -> ForgeQualityRunBinding {
        ForgeQualityRunBinding(
            projectID: id("project-a"),
            sourceRevision: id(sourceRevision),
            checkpointID: id("checkpoint-9"),
            runtimeRevision: id(runtimeRevision),
            runID: id(runID),
            environmentKind: environmentKind,
            environmentProfileID: id(environmentKind == .physicalDevice ? "iphone12-a14" : "iphone12-ios27-sim"),
            osBuild: id("24A123")
        )
    }

    private func target(
        _ metric: ForgeQualityMetric,
        atMost threshold: Double,
        scope: ForgeQualityScope = .run,
        physical: Bool = false
    ) -> ForgeQualityTarget {
        try! ForgeQualityTarget(
            metric: metric,
            scope: scope,
            comparator: .atMost,
            threshold: threshold,
            requiresPhysicalDevice: physical
        )
    }

    private func completionTarget(
        missionID: String = "mission-1",
        projectID: String = "project-a",
        sourceRevision: String = "source-r2",
        constitutionRevision: UInt64 = 4,
        constitutionReceipt: String = "constitution-receipt-4"
    ) -> ForgeQualityCompletionTarget {
        ForgeQualityCompletionTarget(
            missionID: id(missionID),
            projectID: id(projectID),
            sourceRevision: id(sourceRevision),
            constitutionRevision: constitutionRevision,
            constitutionReceiptID: id(constitutionReceipt)
        )
    }

    private func policy(
        _ targets: [ForgeQualityTarget],
        missionID: String = "mission-1",
        projectID: String = "project-a",
        sourceRevision: String = "source-r2",
        constitutionRevision: UInt64 = 4,
        constitutionReceipt: String = "constitution-receipt-4",
        authorityReceipt: String = "quality-policy-authority-1",
        criterionID: String = "performance-criterion"
    ) -> ForgeQualityPolicy {
        try! ForgeQualityPolicy(
            policyID: id("quality-policy-1"),
            policyAuthorityReceiptID: id(authorityReceipt),
            criterionID: id(criterionID),
            completionTarget: completionTarget(
                missionID: missionID,
                projectID: projectID,
                sourceRevision: sourceRevision,
                constitutionRevision: constitutionRevision,
                constitutionReceipt: constitutionReceipt
            ),
            targets: targets
        )
    }

    private func evaluate(
        policy: ForgeQualityPolicy,
        binding: ForgeQualityRunBinding? = nil,
        acceptedCompletionTarget: ForgeQualityCompletionTarget? = nil,
        trustedPolicyAuthorityReceipt: String = "quality-policy-authority-1",
        measurements: [ForgeQualityMeasurement]
    ) throws -> ForgeQualityAssessment {
        try ForgeQualityEvaluator.evaluate(
            policy: policy,
            trustedPolicyAuthorityReceiptID: id(trustedPolicyAuthorityReceipt),
            acceptedCompletionTarget: acceptedCompletionTarget ?? completionTarget(),
            binding: binding ?? self.binding(),
            measurements: measurements
        )
    }

    private func measurement(
        _ metric: ForgeQualityMetric,
        value: Double,
        receipt: String,
        binding: ForgeQualityRunBinding? = nil,
        scope: ForgeQualityScope = .run
    ) -> ForgeQualityMeasurement {
        try! ForgeQualityMeasurement(
            receiptID: id(receipt),
            binding: binding ?? self.binding(),
            metric: metric,
            scope: scope,
            evidenceKind: metric.expectedEvidenceKind,
            value: value
        )
    }

    @Test func identifiersRejectWhitespaceAndControls() throws {
        #expect(throws: ForgeQualityError.invalidIdentifier) { try ForgeQualityID(" project-a") }
        #expect(throws: ForgeQualityError.invalidIdentifier) { try ForgeQualityID("project-a\n") }
        #expect(throws: ForgeQualityError.invalidIdentifier) { try ForgeQualityID("") }
        #expect(try ForgeQualityID("project-a").rawValue == "project-a")
    }

    @Test func policyRejectsDuplicateMetricsAndInvalidThresholds() throws {
        let frame = target(.p95FrameTimeMilliseconds, atMost: 20)
        #expect(throws: ForgeQualityError.duplicateTarget(metric: .p95FrameTimeMilliseconds, scope: .run)) {
            try ForgeQualityPolicy(
                policyID: id("p"),
                policyAuthorityReceiptID: id("quality-policy-authority-1"),
                criterionID: id("performance-criterion"),
                completionTarget: completionTarget(),
                targets: [frame, frame]
            )
        }
        #expect(throws: ForgeQualityError.invalidThreshold(.longFrameRatePercent)) {
            try ForgeQualityTarget(metric: .longFrameRatePercent, comparator: .atMost, threshold: 101)
        }
        #expect(throws: ForgeQualityError.invalidThreshold(.fatalRuntimeErrorCount)) {
            try ForgeQualityTarget(metric: .fatalRuntimeErrorCount, comparator: .atMost, threshold: 0.5)
        }
    }

    @Test func measurementRejectsWrongEvidenceKindAndNonFiniteValue() throws {
        #expect(throws: ForgeQualityError.evidenceKindMismatch(
            metric: .p95FrameTimeMilliseconds,
            expected: .runtimeTelemetry,
            actual: .accessibilityAudit
        )) {
            try ForgeQualityMeasurement(
                receiptID: id("r1"),
                binding: binding(),
                metric: .p95FrameTimeMilliseconds,
                evidenceKind: .accessibilityAudit,
                value: 12
            )
        }
        #expect(throws: ForgeQualityError.invalidMeasurement(.p95FrameTimeMilliseconds)) {
            try ForgeQualityMeasurement(
                receiptID: id("r1"),
                binding: binding(),
                metric: .p95FrameTimeMilliseconds,
                evidenceKind: .runtimeTelemetry,
                value: .infinity
            )
        }
    }

    @Test func exactEvidenceCanPassQualityGate() throws {
        let currentBinding = binding()
        let currentPolicy = policy([
            target(.p95FrameTimeMilliseconds, atMost: 20),
            target(.fatalRuntimeErrorCount, atMost: 0),
            target(.accessibilityCriticalViolationCount, atMost: 0),
        ])
        let measurements = [
            measurement(.p95FrameTimeMilliseconds, value: 16.5, receipt: "perf-1", binding: currentBinding),
            measurement(.fatalRuntimeErrorCount, value: 0, receipt: "runtime-1", binding: currentBinding),
            measurement(.accessibilityCriticalViolationCount, value: 0, receipt: "a11y-1", binding: currentBinding),
        ]

        let result = try evaluate(
            policy: currentPolicy,
            binding: currentBinding,
            measurements: measurements
        )

        #expect(result.status == .passed)
        #expect(result.findings.isEmpty)
        #expect(result.acceptedReceiptIDs == [id("a11y-1"), id("perf-1"), id("runtime-1")])
    }

    @Test func missingEvidenceBlocksRatherThanPasses() throws {
        let result = try evaluate(
            policy: policy([
                target(.p95FrameTimeMilliseconds, atMost: 20),
                target(.fatalRuntimeErrorCount, atMost: 0),
            ]),
            binding: binding(),
            measurements: [measurement(.fatalRuntimeErrorCount, value: 0, receipt: "runtime-1")]
        )

        #expect(result.status == .blocked)
        #expect(result.findings.map(\.reason) == [.missingEvidence])
        #expect(result.acceptedReceiptIDs.isEmpty)
        #expect(result.supportingReceiptIDs == [id("runtime-1")])
    }

    @Test func exceededThresholdFailsEvenWhenOtherEvidenceIsMissing() throws {
        let result = try evaluate(
            policy: policy([
                target(.p95FrameTimeMilliseconds, atMost: 20),
                target(.accessibilityCriticalViolationCount, atMost: 0),
            ]),
            binding: binding(),
            measurements: [measurement(.p95FrameTimeMilliseconds, value: 28, receipt: "perf-1")]
        )

        #expect(result.status == .failed)
        #expect(Set(result.findings.map(\.reason)) == [.thresholdExceeded, .missingEvidence])
        #expect(result.acceptedReceiptIDs.isEmpty)
    }

    @Test func unsupportedComparatorFailsClosed() throws {
        #expect(throws: ForgeQualityError.unsupportedComparator(
            metric: .inputLatencyP95Milliseconds,
            comparator: .atLeast
        )) {
            try ForgeQualityTarget(
                metric: .inputLatencyP95Milliseconds,
                comparator: .atLeast,
                threshold: 5
            )
        }
    }

    @Test func staleSourceEvidenceIsRejected() throws {
        let stale = binding(sourceRevision: "source-r1")
        let current = binding(sourceRevision: "source-r2")
        #expect(throws: ForgeQualityError.evidenceBindingMismatch(receiptID: id("perf-1"))) {
            try evaluate(
                policy: policy([target(.p95FrameTimeMilliseconds, atMost: 20)]),
                binding: current,
                measurements: [measurement(.p95FrameTimeMilliseconds, value: 16, receipt: "perf-1", binding: stale)]
            )
        }
    }

    @Test func runtimeAndRunReplayAreRejected() throws {
        let current = binding(runtimeRevision: "runtime-r7", runID: "run-2")
        let oldRun = binding(runtimeRevision: "runtime-r6", runID: "run-1")
        #expect(throws: ForgeQualityError.evidenceBindingMismatch(receiptID: id("perf-1"))) {
            try evaluate(
                policy: policy([target(.p95FrameTimeMilliseconds, atMost: 20)]),
                binding: current,
                measurements: [measurement(.p95FrameTimeMilliseconds, value: 16, receipt: "perf-1", binding: oldRun)]
            )
        }
    }

    @Test func physicalDeviceRequirementDoesNotAcceptSimulatorSample() throws {
        let currentPolicy = policy([target(.p95FrameTimeMilliseconds, atMost: 20, physical: true)])
        let simulatorBinding = binding(environmentKind: .simulator)
        let result = try evaluate(
            policy: currentPolicy,
            binding: simulatorBinding,
            measurements: [measurement(.p95FrameTimeMilliseconds, value: 12, receipt: "perf-1", binding: simulatorBinding)]
        )
        #expect(result.status == .blocked)
        #expect(result.findings.first?.reason == .physicalDeviceRequired)
        #expect(result.acceptedReceiptIDs.isEmpty)
    }

    @Test func physicalDeviceEvidenceCanSatisfyPhysicalTarget() throws {
        let deviceBinding = binding(environmentKind: .physicalDevice)
        let result = try evaluate(
            policy: policy([target(.p95FrameTimeMilliseconds, atMost: 20, physical: true)]),
            binding: deviceBinding,
            measurements: [measurement(.p95FrameTimeMilliseconds, value: 18, receipt: "perf-device", binding: deviceBinding)]
        )
        #expect(result.status == .passed)
        #expect(result.acceptedReceiptIDs == [id("perf-device")])
    }

    @Test func duplicateMetricsAndReceiptReuseFailClosed() throws {
        let perfPolicy = policy([
            target(.p95FrameTimeMilliseconds, atMost: 20),
            target(.p99FrameTimeMilliseconds, atMost: 30),
        ])
        #expect(throws: ForgeQualityError.duplicateMeasurement(metric: .p95FrameTimeMilliseconds, scope: .run)) {
            try evaluate(
                policy: perfPolicy,
                binding: binding(),
                measurements: [
                    measurement(.p95FrameTimeMilliseconds, value: 15, receipt: "r1"),
                    measurement(.p95FrameTimeMilliseconds, value: 16, receipt: "r2"),
                ]
            )
        }
        #expect(throws: ForgeQualityError.duplicateReceiptID(id("r1"))) {
            try evaluate(
                policy: perfPolicy,
                binding: binding(),
                measurements: [
                    measurement(.p95FrameTimeMilliseconds, value: 15, receipt: "r1"),
                    measurement(.p99FrameTimeMilliseconds, value: 22, receipt: "r1"),
                ]
            )
        }
    }

    @Test func unexpectedMetricsDoNotPolluteAcceptance() throws {
        #expect(throws: ForgeQualityError.unexpectedMeasurement(metric: .p99FrameTimeMilliseconds, scope: .run)) {
            try evaluate(
                policy: policy([target(.p95FrameTimeMilliseconds, atMost: 20)]),
                binding: binding(),
                measurements: [measurement(.p99FrameTimeMilliseconds, value: 22, receipt: "perf-extra")]
            )
        }
    }

    @Test func sameMetricCanBeRequiredForDistinctJourneyScopes() throws {
        let goalScope = ForgeQualityScope.journey(id("goal-journey"))
        let chaosScope = ForgeQualityScope.journey(id("chaos-journey"))
        let currentPolicy = policy([
            target(.p95FrameTimeMilliseconds, atMost: 20, scope: goalScope),
            target(.p95FrameTimeMilliseconds, atMost: 24, scope: chaosScope),
        ])
        let result = try evaluate(
            policy: currentPolicy,
            binding: binding(),
            measurements: [
                measurement(.p95FrameTimeMilliseconds, value: 17, receipt: "goal-perf", scope: goalScope),
                measurement(.p95FrameTimeMilliseconds, value: 22, receipt: "chaos-perf", scope: chaosScope),
            ]
        )
        #expect(result.status == .passed)
        #expect(result.acceptedReceiptIDs == [id("chaos-perf"), id("goal-perf")])
    }

    @Test func performanceFromOneJourneyCannotSatisfyAnotherJourney() throws {
        let goalScope = ForgeQualityScope.journey(id("goal-journey"))
        let performanceScope = ForgeQualityScope.journey(id("performance-journey"))
        let currentPolicy = policy([
            target(.p95FrameTimeMilliseconds, atMost: 20, scope: goalScope),
        ])
        #expect(throws: ForgeQualityError.unexpectedMeasurement(
            metric: .p95FrameTimeMilliseconds,
            scope: performanceScope
        )) {
            try evaluate(
                policy: currentPolicy,
                binding: binding(),
                measurements: [
                    measurement(
                        .p95FrameTimeMilliseconds,
                        value: 15,
                        receipt: "wrong-journey-perf",
                        scope: performanceScope
                    ),
                ]
            )
        }

        let missing = try evaluate(
            policy: currentPolicy,
            binding: binding(),
            measurements: []
        )
        #expect(missing.status == .blocked)
        #expect(missing.findings.first?.scope == goalScope)
    }

    @Test func serializedPolicyAuthorityCannotSelfAuthorize() throws {
        let forgedPolicy = policy(
            [target(.p95FrameTimeMilliseconds, atMost: 20)],
            authorityReceipt: "model-authored-policy-receipt"
        )
        #expect(throws: ForgeQualityError.untrustedPolicyAuthorityReceipt(
            expected: id("host-trusted-policy-receipt"),
            actual: id("model-authored-policy-receipt")
        )) {
            try evaluate(
                policy: forgedPolicy,
                trustedPolicyAuthorityReceipt: "host-trusted-policy-receipt",
                measurements: [measurement(.p95FrameTimeMilliseconds, value: 16, receipt: "perf-1")]
            )
        }
    }

    @Test func qualityPolicyMustMatchExactCompletionTarget() throws {
        let wrongTargetPolicy = policy(
            [target(.p95FrameTimeMilliseconds, atMost: 20)],
            sourceRevision: "source-r1"
        )
        #expect(throws: ForgeQualityError.completionTargetMismatch) {
            try evaluate(
                policy: wrongTargetPolicy,
                binding: binding(sourceRevision: "source-r2"),
                measurements: [measurement(.p95FrameTimeMilliseconds, value: 16, receipt: "perf-1")]
            )
        }
    }

    @Test func acceptedCompletionTargetMustMatchPolicy() throws {
        #expect(throws: ForgeQualityError.completionTargetMismatch) {
            try evaluate(
                policy: policy([target(.fatalRuntimeErrorCount, atMost: 0)]),
                binding: binding(),
                acceptedCompletionTarget: completionTarget(constitutionRevision: 5),
                measurements: [measurement(.fatalRuntimeErrorCount, value: 0, receipt: "runtime-1")]
            )
        }
    }

    @Test func crossMissionCompletionTargetCannotReuseQualityPolicy() throws {
        #expect(throws: ForgeQualityError.completionTargetMismatch) {
            try evaluate(
                policy: policy([target(.p95FrameTimeMilliseconds, atMost: 20)]),
                acceptedCompletionTarget: completionTarget(missionID: "mission-2"),
                measurements: [measurement(.p95FrameTimeMilliseconds, value: 16, receipt: "perf-1")]
            )
        }
    }

    @Test func policyDecodeRevalidatesDuplicateTargets() throws {
        let valid = policy([target(.p95FrameTimeMilliseconds, atMost: 20)])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        let encodedTarget = try #require(object["targets"] as? [[String: Any]])[0]
        object["targets"] = [encodedTarget, encodedTarget]
        let forged = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ForgeQualityPolicy.self, from: forged)
        }
    }

    @Test func measurementDecodeRevalidatesMetricEvidenceKind() throws {
        let valid = measurement(.p95FrameTimeMilliseconds, value: 18, receipt: "perf-1")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["evidenceKind"] = ForgeQualityEvidenceKind.accessibilityAudit.rawValue
        let forged = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ForgeQualityMeasurement.self, from: forged)
        }
    }

    @Test func snapshotRoundTripRederivesAssessment() throws {
        let currentBinding = binding()
        let snapshot = try ForgeQualitySnapshot(
            policy: policy([
                target(.p95FrameTimeMilliseconds, atMost: 20),
                target(.accessibilityCriticalViolationCount, atMost: 0),
            ]),
            binding: currentBinding,
            measurements: [
                measurement(.p95FrameTimeMilliseconds, value: 17, receipt: "perf-1", binding: currentBinding),
                measurement(.accessibilityCriticalViolationCount, value: 0, receipt: "a11y-1", binding: currentBinding),
            ]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ForgeQualitySnapshot.self, from: data)
        #expect(try decoded.assessment(trustedPolicyAuthorityReceiptID: id("quality-policy-authority-1"), acceptedCompletionTarget: completionTarget()).status == .passed)
        #expect(try decoded.assessment(trustedPolicyAuthorityReceiptID: id("quality-policy-authority-1"), acceptedCompletionTarget: completionTarget()).acceptedReceiptIDs == [id("a11y-1"), id("perf-1")])
    }

    @Test func snapshotDecodeRejectsCrossRunMeasurement() throws {
        let currentBinding = binding(runID: "run-2")
        let staleBinding = binding(runID: "run-1")
        let currentPolicy = policy([target(.p95FrameTimeMilliseconds, atMost: 20)])
        let encodedPolicy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(currentPolicy))
        let encodedBinding = try JSONSerialization.jsonObject(with: JSONEncoder().encode(currentBinding))
        let encodedMeasurement = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(measurement(.p95FrameTimeMilliseconds, value: 17, receipt: "perf-1", binding: staleBinding))
        )
        let object: [String: Any] = [
            "schemaVersion": 1,
            "policy": encodedPolicy,
            "binding": encodedBinding,
            "measurements": [encodedMeasurement],
        ]
        let forged = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ForgeQualitySnapshot.self, from: forged)
        }
    }
}
