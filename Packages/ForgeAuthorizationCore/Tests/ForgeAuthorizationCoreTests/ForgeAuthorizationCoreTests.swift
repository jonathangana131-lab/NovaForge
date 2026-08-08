import XCTest
import ForgePlanCore
@testable import ForgeAuthorizationCore

final class ForgeAuthorizationCoreTests: XCTestCase {
    private func authority(
        checkpointID: String = "checkpoint-1",
        missionRevision: UInt64 = 1,
        authorityEpoch: UInt64 = 1
    ) throws -> ForgeAuthorizationAuthority {
        try ForgeAuthorizationAuthority(
            projectID: "project-1",
            missionID: "mission-1",
            checkpointID: checkpointID,
            missionRevision: missionRevision,
            authorityEpoch: authorityEpoch
        )
    }

    private func limits(
        files: Int = 12,
        seconds: Int = 600,
        thermal: ForgeAuthorizationThermalLoad = .moderate
    ) throws -> ForgeActionResourceLimits {
        try ForgeActionResourceLimits(
            maxMutationFiles: files,
            maxWallClockSeconds: seconds,
            maxThermalLoad: thermal
        )
    }

    private func policy(
        autonomy: ForgeAutonomy,
        privacy: ForgeAuthorizationPrivacyMode = .localOnly,
        providers: Set<String> = [],
        highRisk: Set<ForgeAuthorizationActionKind> = [],
        authority: ForgeAuthorizationAuthority? = nil
    ) throws -> ForgeAuthorizationPolicy {
        try ForgeAuthorizationPolicy(
            policyID: "policy-1",
            revision: "rev-1",
            authority: try authority ?? self.authority(),
            autonomy: autonomy,
            privacyMode: privacy,
            approvedProviderIDs: providers,
            approvableHighRiskActions: highRisk,
            resourceLimits: limits()
        )
    }

    private func request(
        action: ForgeAuthorizationActionKind,
        requestID: String = "request-1",
        authority: ForgeAuthorizationAuthority? = nil,
        scopeID: String = "scope-1",
        locality: ForgeWorkerLocality = .onDevice,
        files: Int? = nil,
        seconds: Int = 30,
        thermal: ForgeAuthorizationThermalLoad = .low,
        decision: ForgeDecisionDependency = .none
    ) throws -> ForgeAuthorizationRequest {
        let resolvedFiles = files ?? (action.canMutateProjectFiles ? 1 : 0)
        return try ForgeAuthorizationRequest(
            requestID: requestID,
            authority: try authority ?? self.authority(),
            scopeID: scopeID,
            action: action,
            workerLocality: locality,
            mutationFileLimit: resolvedFiles,
            requestedWallClockSeconds: seconds,
            requestedThermalLoad: thermal,
            decisionDependency: decision
        )
    }

    func testAskAutomaticallyAllowsOnlyReadOnlyWork() throws {
        let p = try policy(autonomy: .ask)
        let read = try request(action: .readOnlyInspection)
        let state = try request(action: .reversibleProjectState, requestID: "request-2")

        guard case let .allowed(receipt) = ForgeAuthorizationEvaluator.evaluate(policy: p, request: read) else {
            return XCTFail("read-only work should be automatic")
        }
        XCTAssertEqual(receipt.mode, .automatic)
        XCTAssertEqual(ForgeAuthorizationEvaluator.evaluate(policy: p, request: state), .denied(.approvalRequired))
    }

    func testAssistAllowsReversibleStateAndRuntimeInteractionButNotSourceMutation() throws {
        let p = try policy(autonomy: .assist)
        XCTAssertNotNil(allowedReceipt(ForgeAuthorizationEvaluator.evaluate(policy: p, request: try request(action: .reversibleProjectState))))
        XCTAssertNotNil(allowedReceipt(ForgeAuthorizationEvaluator.evaluate(policy: p, request: try request(action: .runtimeSemanticInteraction, requestID: "runtime-1"))))
        XCTAssertNotNil(allowedReceipt(ForgeAuthorizationEvaluator.evaluate(policy: p, request: try request(action: .runtimeRestart, requestID: "runtime-2"))))
        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: try request(action: .projectSourceMutation, requestID: "request-2")),
            .denied(.approvalRequired)
        )
    }

    func testBuildAndAutopilotAllowBoundedProjectMutationButOnlyAutopilotSignalsContinuousIntent() throws {
        let build = try policy(autonomy: .build)
        let autopilot = try policy(autonomy: .autopilot)
        let mutation = try request(action: .projectSourceMutation)

        XCTAssertNotNil(allowedReceipt(ForgeAuthorizationEvaluator.evaluate(policy: build, request: mutation)))
        XCTAssertNotNil(allowedReceipt(ForgeAuthorizationEvaluator.evaluate(policy: autopilot, request: mutation)))
        XCTAssertFalse(build.allowsContinuousExecutionIntent)
        XCTAssertTrue(autopilot.allowsContinuousExecutionIntent)
    }

    func testAutopilotNeverSilentlyAuthorizesHighRiskWork() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: try request(action: .remoteMutation)),
            .denied(.approvalRequired)
        )
    }

    func testAcceptedApprovalAuthorizesOnlyEnabledHighRiskRequest() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let r = try request(action: .remoteMutation)
        let approval = try ForgeAcceptedApproval(
            approvalReceiptID: "approval-receipt-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: r
        )

        guard case let .allowed(receipt) = ForgeAuthorizationEvaluator.evaluate(policy: p, request: r, approval: approval) else {
            return XCTFail("exact accepted approval should authorize enabled R3 work")
        }
        XCTAssertEqual(receipt.mode, .acceptedApproval(receiptID: "approval-receipt-1"))
    }

    func testApprovalCannotBeReusedForDifferentScope() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let original = try request(action: .remoteMutation)
        let different = try request(action: .remoteMutation, scopeID: "scope-2")
        let approval = try ForgeAcceptedApproval(
            approvalReceiptID: "approval-receipt-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: original
        )

        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: different, approval: approval),
            .denied(.approvalDoesNotMatchExactRequest)
        )
    }

    func testApprovalCannotCrossCheckpointOrAuthorityEpoch() throws {
        let firstAuthority = try authority()
        let p = try policy(autonomy: .autopilot, highRisk: [.publish], authority: firstAuthority)
        let original = try request(action: .publish, authority: firstAuthority)
        let approval = try ForgeAcceptedApproval(
            approvalReceiptID: "approval-receipt-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: original
        )

        let advancedAuthority = try authority(checkpointID: "checkpoint-2", missionRevision: 2, authorityEpoch: 2)
        let advancedRequest = try request(action: .publish, authority: advancedAuthority)
        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: advancedRequest, approval: approval),
            .denied(.authorityIdentityMismatch)
        )
    }

    func testAcceptedApprovalCannotBypassHighRiskPolicyEnablement() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(action: .publish)
        let approval = try ForgeAcceptedApproval(
            approvalReceiptID: "approval-receipt-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: r
        )

        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: r, approval: approval),
            .denied(.highRiskActionNotEnabled)
        )
    }

    func testUnavailableHostAuthorityIsNeverApprovable() throws {
        let p = try policy(autonomy: .autopilot)
        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: try request(action: .unsupportedHostAuthority)),
            .denied(.actionUnavailable)
        )
    }

    func testLocalOnlyRejectsHostedWorkerEvenForReadOnlyWork() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(action: .readOnlyInspection, locality: .hostedProvider(providerID: "provider-a"))
        XCTAssertEqual(ForgeAuthorizationEvaluator.evaluate(policy: p, request: r), .denied(.hostedProviderDenied))
    }

    func testHostedWorkerRequiresExactApprovedProvider() throws {
        let p = try policy(
            autonomy: .assist,
            privacy: .approvedProviders,
            providers: ["provider-a"]
        )
        let allowed = try request(action: .readOnlyInspection, locality: .hostedProvider(providerID: "provider-a"))
        let denied = try request(
            action: .readOnlyInspection,
            requestID: "request-2",
            locality: .hostedProvider(providerID: "provider-b")
        )

        XCTAssertNotNil(allowedReceipt(ForgeAuthorizationEvaluator.evaluate(policy: p, request: allowed)))
        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: denied),
            .denied(.providerNotApproved(providerID: "provider-b"))
        )
    }

    func testResourceLimitsCannotBeOverriddenByApproval() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.destructiveProjectMutation])
        let oversized = try request(action: .destructiveProjectMutation, files: 13)
        let approval = try ForgeAcceptedApproval(
            approvalReceiptID: "approval-receipt-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: oversized
        )

        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: oversized, approval: approval),
            .denied(.mutationFileBudgetExceeded(limit: 12))
        )
    }

    func testThermalAndTimeLimitsFailClosed() throws {
        let p = try policy(autonomy: .autopilot)
        let hot = try request(action: .readOnlyInspection, thermal: .high)
        let long = try request(action: .readOnlyInspection, requestID: "request-2", seconds: 601)
        XCTAssertEqual(ForgeAuthorizationEvaluator.evaluate(policy: p, request: hot), .denied(.thermalBudgetExceeded(limit: .moderate)))
        XCTAssertEqual(ForgeAuthorizationEvaluator.evaluate(policy: p, request: long), .denied(.wallClockBudgetExceeded(limitSeconds: 600)))
    }

    func testUnresolvedMaterialDecisionStopsExecutionEvenInAutopilot() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(
            action: .projectSourceMutation,
            decision: .unresolvedMaterial(decisionID: "decision-1")
        )
        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: r),
            .denied(.unresolvedMaterialDecision(decisionID: "decision-1"))
        )
    }

    func testAcceptedDecisionReceiptMayCrossWithoutMintingDecisionTruth() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(
            action: .projectSourceMutation,
            decision: .accepted(decisionID: "decision-1", receiptID: "decision-receipt-1")
        )
        XCTAssertNotNil(allowedReceipt(ForgeAuthorizationEvaluator.evaluate(policy: p, request: r)))
    }

    func testAuthorityMismatchFailsClosed() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(action: .readOnlyInspection, authority: try authority(checkpointID: "checkpoint-2"))
        XCTAssertEqual(ForgeAuthorizationEvaluator.evaluate(policy: p, request: r), .denied(.authorityIdentityMismatch))
    }

    func testLocalOnlyPolicyCannotCarryApprovedHostedProviders() throws {
        XCTAssertThrowsError(
            try ForgeAuthorizationPolicy(
                policyID: "policy-1",
                revision: "rev-1",
                authority: authority(),
                autonomy: .autopilot,
                privacyMode: .localOnly,
                approvedProviderIDs: ["provider-a"],
                resourceLimits: limits()
            )
        )
    }

    func testHighRiskEnablementCannotContainLowerRiskActions() throws {
        XCTAssertThrowsError(
            try ForgeAuthorizationPolicy(
                policyID: "policy-1",
                revision: "rev-1",
                authority: authority(),
                autonomy: .autopilot,
                privacyMode: .localOnly,
                approvableHighRiskActions: [.projectSourceMutation],
                resourceLimits: limits()
            )
        )
    }

    func testOpaqueIdentityRejectsPathLikeApprovalReceipt() throws {
        XCTAssertThrowsError(
            try ForgeAcceptedApproval(
                approvalReceiptID: "../../approval",
                policyID: "policy-1",
                policyRevision: "rev-1",
                request: request(action: .remoteMutation)
            )
        )
    }

    func testOpaqueAuthorityRejectsPathLikeCheckpoint() throws {
        XCTAssertThrowsError(
            try ForgeAuthorizationAuthority(
                projectID: "project-1",
                missionID: "mission-1",
                checkpointID: "../../checkpoint",
                missionRevision: 1,
                authorityEpoch: 1
            )
        )
    }

    func testApprovalCannotBeReusedWhenResourceAllotmentChanges() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.destructiveProjectMutation])
        let original = try request(action: .destructiveProjectMutation, files: 2)
        let widened = try request(action: .destructiveProjectMutation, files: 8)
        let approval = try ForgeAcceptedApproval(
            approvalReceiptID: "approval-receipt-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: original
        )

        XCTAssertEqual(
            ForgeAuthorizationEvaluator.evaluate(policy: p, request: widened, approval: approval),
            .denied(.approvalDoesNotMatchExactRequest)
        )
    }

    func testMutationAllotmentMustMatchActionSemantics() throws {
        XCTAssertThrowsError(
            try request(action: .readOnlyInspection, files: 1)
        )
        XCTAssertThrowsError(
            try request(action: .projectSourceMutation, files: 0)
        )
    }

    func testAcceptedDecisionRequiresExactOpaqueDecisionAndReceiptIdentity() throws {
        XCTAssertThrowsError(
            try request(
                action: .projectSourceMutation,
                decision: .accepted(decisionID: "../../decision", receiptID: "decision-receipt-1")
            )
        )
        XCTAssertThrowsError(
            try request(
                action: .projectSourceMutation,
                decision: .accepted(decisionID: "decision-1", receiptID: "../../receipt")
            )
        )
    }

    func testReceiptProjectionRequiresExactRevalidation() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let r = try request(action: .remoteMutation)
        let approval = try ForgeAcceptedApproval(
            approvalReceiptID: "approval-receipt-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: r
        )
        guard case let .allowed(receipt) = ForgeAuthorizationEvaluator.evaluate(policy: p, request: r, approval: approval) else {
            return XCTFail("expected exact approved receipt")
        }

        let bytes = try JSONEncoder().encode(receipt.projection)
        let restored = try JSONDecoder().decode(ForgeAuthorizationReceiptProjection.self, from: bytes)
        XCTAssertNotNil(allowedReceipt(ForgeAuthorizationEvaluator.revalidate(
            projection: restored,
            policy: p,
            request: r,
            approval: approval
        )))
    }

    func testReceiptProjectionBindsExactResourceAndLocalityConstraints() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(action: .projectSourceMutation, files: 2, seconds: 40)
        guard case let .allowed(receipt) = ForgeAuthorizationEvaluator.evaluate(policy: p, request: r) else {
            return XCTFail("expected automatic R2 receipt")
        }
        let data = try JSONEncoder().encode(receipt.projection)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["mutationFileLimit"] = 8
        let forgedBytes = try JSONSerialization.data(withJSONObject: object)
        let forged = try JSONDecoder().decode(ForgeAuthorizationReceiptProjection.self, from: forgedBytes)

        XCTAssertEqual(
            ForgeAuthorizationEvaluator.revalidate(projection: forged, policy: p, request: r),
            .denied(.receiptProjectionMismatch)
        )
    }

    func testReceiptProjectionCannotCrossAuthorityAdvance() throws {
        let firstAuthority = try authority()
        let p = try policy(autonomy: .autopilot, authority: firstAuthority)
        let r = try request(action: .projectSourceMutation, authority: firstAuthority)
        guard case let .allowed(receipt) = ForgeAuthorizationEvaluator.evaluate(policy: p, request: r) else {
            return XCTFail("expected automatic R2 receipt")
        }
        let advancedAuthority = try authority(checkpointID: "checkpoint-2", missionRevision: 2, authorityEpoch: 2)
        let advancedPolicy = try policy(autonomy: .autopilot, authority: advancedAuthority)
        let advancedRequest = try request(action: .projectSourceMutation, authority: advancedAuthority)
        XCTAssertEqual(
            ForgeAuthorizationEvaluator.revalidate(
                projection: receipt.projection,
                policy: advancedPolicy,
                request: advancedRequest
            ),
            .denied(.receiptProjectionMismatch)
        )
    }

    func testForgedReceiptProjectionDoesNotRestoreAuthorization() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let r = try request(action: .remoteMutation)
        let approval = try ForgeAcceptedApproval(
            approvalReceiptID: "approval-receipt-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: r
        )
        guard case let .allowed(receipt) = ForgeAuthorizationEvaluator.evaluate(policy: p, request: r, approval: approval) else {
            return XCTFail("expected exact approved receipt")
        }
        let original = receipt.projection
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["mode"] = ["automatic": [:]]
        let forgedBytes = try JSONSerialization.data(withJSONObject: object)
        let forged = try JSONDecoder().decode(ForgeAuthorizationReceiptProjection.self, from: forgedBytes)

        XCTAssertEqual(
            ForgeAuthorizationEvaluator.revalidate(
                projection: forged,
                policy: p,
                request: r,
                approval: approval
            ),
            .denied(.receiptProjectionMismatch)
        )
    }

    func testAcceptedApprovalRequiresNonblankOpaqueProvenanceReceipt() throws {
        XCTAssertThrowsError(
            try ForgeAcceptedApproval(
                approvalReceiptID: "",
                policyID: "policy-1",
                policyRevision: "rev-1",
                request: request(action: .publish)
            )
        )
    }

    private func allowedReceipt(_ decision: ForgeAuthorizationDecision) -> ForgeAuthorizationReceipt? {
        guard case let .allowed(receipt) = decision else { return nil }
        return receipt
    }
}
