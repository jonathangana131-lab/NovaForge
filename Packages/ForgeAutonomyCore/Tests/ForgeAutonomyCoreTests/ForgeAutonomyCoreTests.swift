import XCTest
import ForgePlanCore
@testable import ForgeAutonomyCore

final class ForgeAutonomyCoreTests: XCTestCase {
    private func budget(
        files: Int = 12,
        seconds: Int = 600,
        thermal: ForgeThermalLoad = .moderate
    ) throws -> ForgeAutonomyBudget {
        try ForgeAutonomyBudget(
            maxMutationFiles: files,
            maxWallClockSeconds: seconds,
            maxThermalLoad: thermal
        )
    }

    private func policy(
        autonomy: ForgeAutonomy,
        privacy: ForgePrivacyMode = .localOnly,
        providers: Set<String> = [],
        highRisk: Set<ForgeActionKind> = []
    ) throws -> ForgeAutonomyPolicy {
        try ForgeAutonomyPolicy(
            policyID: "policy-1",
            revision: "rev-1",
            projectID: "project-1",
            missionID: "mission-1",
            autonomy: autonomy,
            privacyMode: privacy,
            approvedProviderIDs: providers,
            approvableHighRiskActions: highRisk,
            budget: budget()
        )
    }

    private func request(
        action: ForgeActionKind,
        requestID: String = "request-1",
        projectID: String = "project-1",
        missionID: String = "mission-1",
        scopeID: String = "scope-1",
        locality: ForgeWorkerLocality = .onDevice,
        files: Int = 0,
        seconds: Int = 30,
        thermal: ForgeThermalLoad = .low,
        decision: ForgeDecisionDependency = .none
    ) throws -> ForgeAutonomyRequest {
        try ForgeAutonomyRequest(
            requestID: requestID,
            projectID: projectID,
            missionID: missionID,
            scopeID: scopeID,
            action: action,
            workerLocality: locality,
            mutationFileLimit: files,
            requestedWallClockSeconds: seconds,
            requestedThermalLoad: thermal,
            decisionDependency: decision
        )
    }

    func testAskAutomaticallyAllowsOnlyReadOnlyWork() throws {
        let p = try policy(autonomy: .ask)
        let read = try request(action: .readOnlyInspection)
        let state = try request(action: .reversibleProjectState, requestID: "request-2")

        guard case let .allowed(receipt) = ForgeAutonomyEvaluator.evaluate(policy: p, request: read) else {
            return XCTFail("read-only work should be automatic")
        }
        XCTAssertEqual(receipt.mode, .automatic)
        XCTAssertEqual(ForgeAutonomyEvaluator.evaluate(policy: p, request: state), .denied(.approvalRequired))
    }

    func testAssistAutomaticallyAllowsReversibleStateButNotSourceMutation() throws {
        let p = try policy(autonomy: .assist)
        XCTAssertNotNil(allowedReceipt(ForgeAutonomyEvaluator.evaluate(policy: p, request: try request(action: .reversibleProjectState))))
        XCTAssertEqual(
            ForgeAutonomyEvaluator.evaluate(policy: p, request: try request(action: .projectSourceMutation, requestID: "request-2")),
            .denied(.approvalRequired)
        )
    }

    func testBuildAndAutopilotAllowBoundedProjectMutationButOnlyAutopilotIsContinuous() throws {
        let build = try policy(autonomy: .build)
        let autopilot = try policy(autonomy: .autopilot)
        let mutation = try request(action: .projectSourceMutation)

        XCTAssertNotNil(allowedReceipt(ForgeAutonomyEvaluator.evaluate(policy: build, request: mutation)))
        XCTAssertNotNil(allowedReceipt(ForgeAutonomyEvaluator.evaluate(policy: autopilot, request: mutation)))
        XCTAssertFalse(build.allowsContinuousExecution)
        XCTAssertTrue(autopilot.allowsContinuousExecution)
    }

    func testAutopilotNeverSilentlyAuthorizesHighRiskWork() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        XCTAssertEqual(
            ForgeAutonomyEvaluator.evaluate(policy: p, request: try request(action: .remoteMutation)),
            .denied(.approvalRequired)
        )
    }

    func testExactApprovalAuthorizesOnlyEnabledHighRiskRequest() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let r = try request(action: .remoteMutation)
        let grant = try ForgeExplicitApproval(
            grantID: "grant-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: r
        )

        guard case let .allowed(receipt) = ForgeAutonomyEvaluator.evaluate(policy: p, request: r, approval: grant) else {
            return XCTFail("exact approval should authorize enabled R3 work")
        }
        XCTAssertEqual(receipt.mode, .explicitApproval(grantID: "grant-1"))
    }

    func testApprovalCannotBeReusedForDifferentScope() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let original = try request(action: .remoteMutation)
        let different = try request(action: .remoteMutation, scopeID: "scope-2")
        let grant = try ForgeExplicitApproval(
            grantID: "grant-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: original
        )

        XCTAssertEqual(
            ForgeAutonomyEvaluator.evaluate(policy: p, request: different, approval: grant),
            .denied(.approvalDoesNotMatchExactRequest)
        )
    }

    func testExplicitApprovalCannotBypassHighRiskPolicyEnablement() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(action: .publish)
        let grant = try ForgeExplicitApproval(
            grantID: "grant-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: r
        )

        XCTAssertEqual(
            ForgeAutonomyEvaluator.evaluate(policy: p, request: r, approval: grant),
            .denied(.highRiskActionNotEnabled)
        )
    }

    func testUnavailableHostAuthorityIsNeverApprovable() throws {
        let p = try policy(autonomy: .autopilot)
        XCTAssertEqual(
            ForgeAutonomyEvaluator.evaluate(policy: p, request: try request(action: .unsupportedHostAuthority)),
            .denied(.actionUnavailable)
        )
    }

    func testLocalOnlyRejectsHostedWorkerEvenForReadOnlyWork() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(action: .readOnlyInspection, locality: .hostedProvider(providerID: "provider-a"))
        XCTAssertEqual(ForgeAutonomyEvaluator.evaluate(policy: p, request: r), .denied(.hostedProviderDenied))
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

        XCTAssertNotNil(allowedReceipt(ForgeAutonomyEvaluator.evaluate(policy: p, request: allowed)))
        XCTAssertEqual(
            ForgeAutonomyEvaluator.evaluate(policy: p, request: denied),
            .denied(.providerNotApproved(providerID: "provider-b"))
        )
    }

    func testResourceBudgetCannotBeOverriddenByApproval() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let oversized = try request(action: .remoteMutation, files: 13)
        let grant = try ForgeExplicitApproval(
            grantID: "grant-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: oversized
        )

        XCTAssertEqual(
            ForgeAutonomyEvaluator.evaluate(policy: p, request: oversized, approval: grant),
            .denied(.mutationFileBudgetExceeded(limit: 12))
        )
    }

    func testThermalAndTimeBudgetsFailClosed() throws {
        let p = try policy(autonomy: .autopilot)
        let hot = try request(action: .readOnlyInspection, thermal: .high)
        let long = try request(action: .readOnlyInspection, requestID: "request-2", seconds: 601)
        XCTAssertEqual(ForgeAutonomyEvaluator.evaluate(policy: p, request: hot), .denied(.thermalBudgetExceeded(limit: .moderate)))
        XCTAssertEqual(ForgeAutonomyEvaluator.evaluate(policy: p, request: long), .denied(.wallClockBudgetExceeded(limitSeconds: 600)))
    }

    func testUnresolvedMaterialDecisionStopsExecutionEvenInAutopilot() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(
            action: .projectSourceMutation,
            decision: .unresolvedMaterial(decisionID: "decision-1")
        )
        XCTAssertEqual(
            ForgeAutonomyEvaluator.evaluate(policy: p, request: r),
            .denied(.unresolvedMaterialDecision(decisionID: "decision-1"))
        )
    }

    func testAcceptedDecisionReceiptMayCrossPolicyWithoutMintingDecisionTruth() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(
            action: .projectSourceMutation,
            decision: .accepted(receiptID: "decision-receipt-1")
        )
        XCTAssertNotNil(allowedReceipt(ForgeAutonomyEvaluator.evaluate(policy: p, request: r)))
    }

    func testProjectIdentityMismatchFailsClosed() throws {
        let p = try policy(autonomy: .autopilot)
        let r = try request(action: .readOnlyInspection, projectID: "project-2")
        XCTAssertEqual(ForgeAutonomyEvaluator.evaluate(policy: p, request: r), .denied(.authorityIdentityMismatch))
    }

    func testLocalOnlyPolicyCannotCarryApprovedHostedProviders() throws {
        XCTAssertThrowsError(
            try ForgeAutonomyPolicy(
                policyID: "policy-1",
                revision: "rev-1",
                projectID: "project-1",
                missionID: "mission-1",
                autonomy: .autopilot,
                privacyMode: .localOnly,
                approvedProviderIDs: ["provider-a"],
                budget: budget()
            )
        )
    }

    func testHighRiskEnablementCannotContainLowerRiskActions() throws {
        XCTAssertThrowsError(
            try ForgeAutonomyPolicy(
                policyID: "policy-1",
                revision: "rev-1",
                projectID: "project-1",
                missionID: "mission-1",
                autonomy: .autopilot,
                privacyMode: .localOnly,
                approvableHighRiskActions: [.projectSourceMutation],
                budget: budget()
            )
        )
    }

    func testOpaqueIdentityRejectsPathLikeApprovalScope() throws {
        XCTAssertThrowsError(
            try ForgeExplicitApproval(
                grantID: "../../grant",
                policyID: "policy-1",
                policyRevision: "rev-1",
                request: request(action: .remoteMutation)
            )
        )
    }

    func testApprovalCannotBeReusedWhenResourceAllotmentChanges() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let original = try request(action: .remoteMutation, files: 2)
        let widened = try request(action: .remoteMutation, files: 8)
        let grant = try ForgeExplicitApproval(
            grantID: "grant-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: original
        )

        XCTAssertEqual(
            ForgeAutonomyEvaluator.evaluate(policy: p, request: widened, approval: grant),
            .denied(.approvalDoesNotMatchExactRequest)
        )
    }

    func testReceiptProjectionRequiresExactRevalidation() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let r = try request(action: .remoteMutation)
        let grant = try ForgeExplicitApproval(
            grantID: "grant-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: r
        )
        guard case let .allowed(receipt) = ForgeAutonomyEvaluator.evaluate(policy: p, request: r, approval: grant) else {
            return XCTFail("expected exact approved receipt")
        }

        let bytes = try JSONEncoder().encode(receipt.projection)
        let restored = try JSONDecoder().decode(ForgeAuthorizationReceiptProjection.self, from: bytes)
        XCTAssertNotNil(allowedReceipt(ForgeAutonomyEvaluator.revalidate(
            projection: restored,
            policy: p,
            request: r,
            approval: grant
        )))
    }

    func testForgedReceiptProjectionDoesNotRestoreAuthorization() throws {
        let p = try policy(autonomy: .autopilot, highRisk: [.remoteMutation])
        let r = try request(action: .remoteMutation)
        let grant = try ForgeExplicitApproval(
            grantID: "grant-1",
            policyID: p.policyID,
            policyRevision: p.revision,
            request: r
        )
        guard case let .allowed(receipt) = ForgeAutonomyEvaluator.evaluate(policy: p, request: r, approval: grant) else {
            return XCTFail("expected exact approved receipt")
        }
        let forged = ForgeAuthorizationReceiptProjection(
            receipt: ForgeAuthorizationReceipt(
                policyID: receipt.policyID,
                policyRevision: receipt.policyRevision,
                requestID: receipt.requestID,
                projectID: receipt.projectID,
                missionID: receipt.missionID,
                scopeID: receipt.scopeID,
                action: receipt.action,
                mode: .automatic
            )
        )

        XCTAssertEqual(
            ForgeAutonomyEvaluator.revalidate(
                projection: forged,
                policy: p,
                request: r,
                approval: grant
            ),
            .denied(.receiptProjectionMismatch)
        )
    }

    private func allowedReceipt(_ decision: ForgeAutonomyDecision) -> ForgeAuthorizationReceipt? {
        guard case let .allowed(receipt) = decision else { return nil }
        return receipt
    }
}
