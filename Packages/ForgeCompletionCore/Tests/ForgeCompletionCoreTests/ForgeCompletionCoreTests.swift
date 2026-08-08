import Foundation
import Testing
@testable import ForgeCompletionCore

private func id(_ value: String) -> ForgeCompletionIdentifier {
    try! ForgeCompletionIdentifier(value)
}

private let projectID = id("project-alpha")
private let sourceRevision = id("source-abc123")
private let missionID = id("mission-1")

private func requirement(
    _ name: String,
    _ evidenceClass: ForgeCompletionEvidenceClass,
    required: Bool = true,
    minimum: Int = 1
) -> ForgeCompletionRequirement {
    try! ForgeCompletionRequirement(
        id: id(name),
        evidenceClass: evidenceClass,
        isRequired: required,
        minimumPassingReceipts: minimum
    )
}

private func constitution(
    requirements: [ForgeCompletionRequirement],
    limitations: ForgeCompletionKnownLimitationsPolicy = .allowExplicitAccepted
) -> ForgeCompletionConstitution {
    try! ForgeCompletionConstitution(
        projectID: projectID,
        sourceRevision: sourceRevision,
        missionID: missionID,
        constitutionRevision: 7,
        requirements: requirements,
        knownLimitationsPolicy: limitations
    )
}

private func binding(
    receipt: String,
    requirement: ForgeCompletionRequirement,
    authority: ForgeCompletionEvidenceAuthority,
    outcome: ForgeCompletionEvidenceOutcome = .passed,
    project: ForgeCompletionIdentifier = projectID,
    source: ForgeCompletionIdentifier = sourceRevision,
    mission: ForgeCompletionIdentifier = missionID,
    revision: Int = 7
) -> ForgeCompletionEvidenceBinding {
    try! ForgeCompletionEvidenceBinding(
        acceptedReceiptID: id(receipt),
        projectID: project,
        sourceRevision: source,
        missionID: mission,
        constitutionRevision: revision,
        requirementID: requirement.id,
        evidenceClass: requirement.evidenceClass,
        authority: authority,
        outcome: outcome
    )
}

@Test func completeRequiresAllRequiredEvidence() throws {
    let build = requirement("build", .build)
    let launch = requirement("launch", .launch)
    let visual = requirement("visual", .visual)
    let contract = constitution(requirements: [build, launch, visual])

    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: contract,
        evidence: [
            binding(receipt: "r-build", requirement: build, authority: .buildSystem),
            binding(receipt: "r-launch", requirement: launch, authority: .runtimeHost),
            binding(receipt: "r-visual", requirement: visual, authority: .visualQA),
        ],
        defects: [],
        knownLimitations: []
    )

    #expect(projection.state == .complete)
    #expect(projection.blockingRequirementIDs.isEmpty)
    #expect(projection.acceptedEvidenceReceiptIDs == [id("r-build"), id("r-launch"), id("r-visual")])
}

@Test func missingEvidenceBlocksCompletion() throws {
    let build = requirement("build", .build)
    let launch = requirement("launch", .launch)
    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: [build, launch]),
        evidence: [binding(receipt: "r-build", requirement: build, authority: .buildSystem)],
        defects: [],
        knownLimitations: []
    )

    #expect(projection.state == .blocked)
    #expect(projection.blockingRequirementIDs == [launch.id])
}

@Test func failedEvidenceRequiresRepairEvenAlongsidePass() throws {
    let runtime = requirement("runtime", .runtimeStability)
    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: [runtime]),
        evidence: [
            binding(receipt: "r-pass", requirement: runtime, authority: .playtestGate),
            binding(receipt: "r-fail", requirement: runtime, authority: .playtestGate, outcome: .failed),
        ],
        defects: [],
        knownLimitations: []
    )

    #expect(projection.state == .repairRequired)
    #expect(projection.failedRequirementIDs == [runtime.id])
}

@Test func minimumReceiptCountIsEnforced() throws {
    let controls = requirement("controls", .controls, minimum: 2)
    let contract = constitution(requirements: [controls])
    let one = binding(receipt: "r-one", requirement: controls, authority: .playtestGate)

    let blocked = try ForgeCompletionEvaluator.evaluate(
        constitution: contract,
        evidence: [one],
        defects: [],
        knownLimitations: []
    )
    #expect(blocked.state == .blocked)

    let complete = try ForgeCompletionEvaluator.evaluate(
        constitution: contract,
        evidence: [one, binding(receipt: "r-two", requirement: controls, authority: .runtimeHost)],
        defects: [],
        knownLimitations: []
    )
    #expect(complete.state == .complete)
}

@Test func optionalRequirementDoesNotBlock() throws {
    let build = requirement("build", .build)
    let persistence = requirement("save", .persistenceRecovery, required: false)
    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: [build, persistence]),
        evidence: [binding(receipt: "r-build", requirement: build, authority: .buildSystem)],
        defects: [],
        knownLimitations: []
    )

    #expect(projection.state == .complete)
    #expect(projection.satisfiedRequirementIDs == [build.id])
}

@Test func staleSourceEvidenceFailsClosed() throws {
    let build = requirement("build", .build)
    let stale = binding(
        receipt: "r-stale",
        requirement: build,
        authority: .buildSystem,
        source: id("source-old")
    )

    #expect(throws: ForgeCompletionValidationError.identityMismatch("evidence:r-stale")) {
        try ForgeCompletionEvaluator.evaluate(
            constitution: constitution(requirements: [build]),
            evidence: [stale],
            defects: [],
            knownLimitations: []
        )
    }
}

@Test func staleConstitutionRevisionEvidenceFailsClosed() throws {
    let build = requirement("build", .build)
    let stale = binding(receipt: "r-stale", requirement: build, authority: .buildSystem, revision: 6)

    #expect(throws: ForgeCompletionValidationError.identityMismatch("evidence:r-stale")) {
        try ForgeCompletionEvaluator.evaluate(
            constitution: constitution(requirements: [build]),
            evidence: [stale],
            defects: [],
            knownLimitations: []
        )
    }
}

@Test func evidenceClassCannotBeRelabeled() throws {
    let build = requirement("build", .build)
    let invalid = try ForgeCompletionEvidenceBinding(
        acceptedReceiptID: id("r-runtime"),
        projectID: projectID,
        sourceRevision: sourceRevision,
        missionID: missionID,
        constitutionRevision: 7,
        requirementID: build.id,
        evidenceClass: .runtimeStability,
        authority: .runtimeHost,
        outcome: .passed
    )

    #expect(throws: ForgeCompletionValidationError.evidenceClassMismatch(requirementID: "build")) {
        try ForgeCompletionEvaluator.evaluate(
            constitution: constitution(requirements: [build]),
            evidence: [invalid],
            defects: [],
            knownLimitations: []
        )
    }
}

@Test func authorityMustMatchEvidenceClass() throws {
    let performance = requirement("performance", .performance)
    let invalid = binding(receipt: "r-fake", requirement: performance, authority: .userAcceptance)

    #expect(throws: ForgeCompletionValidationError.unsupportedAuthority(requirementID: "performance")) {
        try ForgeCompletionEvaluator.evaluate(
            constitution: constitution(requirements: [performance]),
            evidence: [invalid],
            defects: [],
            knownLimitations: []
        )
    }
}

@Test func duplicateReceiptCannotDoubleCount() throws {
    let controls = requirement("controls", .controls, minimum: 2)
    let first = binding(receipt: "same", requirement: controls, authority: .playtestGate)
    let second = binding(receipt: "same", requirement: controls, authority: .runtimeHost)

    #expect(throws: ForgeCompletionValidationError.duplicateEvidenceReceiptID("same")) {
        try ForgeCompletionEvaluator.evaluate(
            constitution: constitution(requirements: [controls]),
            evidence: [first, second],
            defects: [],
            knownLimitations: []
        )
    }
}

@Test func criticalAndHighDefectsRequireRepair() throws {
    let audit = requirement("defects", .defectAudit)
    let defects = [
        ForgeCompletionDefect(id: id("critical"), projectID: projectID, sourceRevision: sourceRevision, severity: .critical, status: .open),
        ForgeCompletionDefect(id: id("high"), projectID: projectID, sourceRevision: sourceRevision, severity: .high, status: .open),
    ]
    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: [audit]),
        evidence: [binding(receipt: "r-audit", requirement: audit, authority: .defectAudit)],
        defects: defects,
        knownLimitations: []
    )

    #expect(projection.state == .repairRequired)
    #expect(projection.repairDefectIDs == [id("critical"), id("high")])
}

@Test func lowerSeverityDefectMustBeDisclosedAndAccepted() throws {
    let audit = requirement("defects", .defectAudit)
    let defect = ForgeCompletionDefect(
        id: id("medium"), projectID: projectID, sourceRevision: sourceRevision, severity: .medium, status: .open
    )
    let contract = constitution(requirements: [audit])
    let evidence = [binding(receipt: "r-audit", requirement: audit, authority: .defectAudit)]

    let hidden = try ForgeCompletionEvaluator.evaluate(
        constitution: contract,
        evidence: evidence,
        defects: [defect],
        knownLimitations: []
    )
    #expect(hidden.state == .blocked)
    #expect(hidden.undisclosedDefectIDs == [defect.id])

    let limitation = try ForgeCompletionKnownLimitation(
        id: id("lim-medium"),
        projectID: projectID,
        sourceRevision: sourceRevision,
        missionID: missionID,
        constitutionRevision: 7,
        summary: "Minor animation mismatch remains on one optional transition.",
        acceptedReceiptID: id("accept-lim-medium"),
        relatedDefectIDs: [defect.id]
    )
    let disclosed = try ForgeCompletionEvaluator.evaluate(
        constitution: contract,
        evidence: evidence,
        defects: [defect],
        knownLimitations: [limitation]
    )
    #expect(disclosed.state == .completeWithKnownLimitations)
    #expect(disclosed.acceptedLimitationReceiptIDs == [id("accept-lim-medium")])
}

@Test func limitationCannotHideCriticalDefect() throws {
    let audit = requirement("defects", .defectAudit)
    let defect = ForgeCompletionDefect(
        id: id("critical"), projectID: projectID, sourceRevision: sourceRevision, severity: .critical, status: .open
    )
    let limitation = try ForgeCompletionKnownLimitation(
        id: id("lim-critical"),
        projectID: projectID,
        sourceRevision: sourceRevision,
        missionID: missionID,
        constitutionRevision: 7,
        summary: "Critical crash is disclosed but still blocks acceptance.",
        acceptedReceiptID: id("accept-critical"),
        relatedDefectIDs: [defect.id]
    )

    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: [audit]),
        evidence: [binding(receipt: "r-audit", requirement: audit, authority: .defectAudit)],
        defects: [defect],
        knownLimitations: [limitation]
    )
    #expect(projection.state == .repairRequired)
    #expect(projection.repairDefectIDs == [defect.id])
}

@Test func limitationCannotReplaceMissingRequiredEvidence() throws {
    let performance = requirement("performance", .performance)
    let limitation = try ForgeCompletionKnownLimitation(
        id: id("lim-perf"),
        projectID: projectID,
        sourceRevision: sourceRevision,
        missionID: missionID,
        constitutionRevision: 7,
        summary: "Performance evidence is not available yet.",
        acceptedReceiptID: id("accept-perf")
    )

    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: [performance]),
        evidence: [],
        defects: [],
        knownLimitations: [limitation]
    )
    #expect(projection.state == .blocked)
    #expect(projection.blockingRequirementIDs == [performance.id])
}

@Test func forbiddenLimitationsKeepOpenMinorDefectInRepair() throws {
    let audit = requirement("defects", .defectAudit)
    let defect = ForgeCompletionDefect(
        id: id("minor"), projectID: projectID, sourceRevision: sourceRevision, severity: .low, status: .open
    )
    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: [audit], limitations: .forbid),
        evidence: [binding(receipt: "r-audit", requirement: audit, authority: .defectAudit)],
        defects: [defect],
        knownLimitations: []
    )
    #expect(projection.state == .repairRequired)
    #expect(projection.repairDefectIDs == [defect.id])
}

@Test func resolvedDefectDoesNotBlockCompletion() throws {
    let audit = requirement("defects", .defectAudit)
    let resolved = ForgeCompletionDefect(
        id: id("fixed"), projectID: projectID, sourceRevision: sourceRevision, severity: .critical, status: .resolved
    )
    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: [audit]),
        evidence: [binding(receipt: "r-audit", requirement: audit, authority: .defectAudit)],
        defects: [resolved],
        knownLimitations: []
    )
    #expect(projection.state == .complete)
}

@Test func unknownDefectReferenceInLimitationFailsClosed() throws {
    let build = requirement("build", .build)
    let limitation = try ForgeCompletionKnownLimitation(
        id: id("lim"),
        projectID: projectID,
        sourceRevision: sourceRevision,
        missionID: missionID,
        constitutionRevision: 7,
        summary: "References a defect that is not in the accepted defect set.",
        acceptedReceiptID: id("accept-lim"),
        relatedDefectIDs: [id("missing-defect")]
    )

    #expect(throws: ForgeCompletionValidationError.unknownRelatedDefectID("missing-defect")) {
        try ForgeCompletionEvaluator.evaluate(
            constitution: constitution(requirements: [build]),
            evidence: [binding(receipt: "r-build", requirement: build, authority: .buildSystem)],
            defects: [],
            knownLimitations: [limitation]
        )
    }
}

@Test func duplicateRequirementIDsAreRejected() {
    let first = requirement("same", .build)
    let second = requirement("same", .launch)

    #expect(throws: ForgeCompletionValidationError.duplicateRequirementID("same")) {
        try ForgeCompletionConstitution(
            projectID: projectID,
            sourceRevision: sourceRevision,
            missionID: missionID,
            constitutionRevision: 7,
            requirements: [first, second],
            knownLimitationsPolicy: .allowExplicitAccepted
        )
    }
}

@Test func gameEvidenceClassesCanAllBeRepresentedWithoutClaimingRuntimeSuccess() throws {
    let pairs: [(ForgeCompletionEvidenceClass, ForgeCompletionEvidenceAuthority)] = [
        (.build, .buildSystem),
        (.launch, .runtimeHost),
        (.runtimeStability, .playtestGate),
        (.controls, .playtestGate),
        (.gameplayGoal, .playtestGate),
        (.persistenceRecovery, .playtestGate),
        (.safeAreaOrientation, .visualQA),
        (.visual, .visualQA),
        (.accessibility, .accessibilityAudit),
        (.performance, .performanceAudit),
        (.defectAudit, .defectAudit),
    ]
    let requirements = try pairs.enumerated().map { index, pair in
        try ForgeCompletionRequirement(
            id: id("req-\(index)"),
            evidenceClass: pair.0,
            minimumPassingReceipts: 1
        )
    }
    let evidence = zip(requirements, pairs).enumerated().map { index, value in
        binding(receipt: "receipt-\(index)", requirement: value.0, authority: value.1.1)
    }

    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: requirements),
        evidence: evidence,
        defects: [],
        knownLimitations: []
    )
    #expect(projection.state == .complete)
    #expect(projection.satisfiedRequirementIDs.count == pairs.count)
}

@Test func failedOptionalEvidenceDoesNotDefineCompletion() throws {
    let build = requirement("build", .build)
    let optionalVisual = requirement("optional-visual", .visual, required: false)
    let projection = try ForgeCompletionEvaluator.evaluate(
        constitution: constitution(requirements: [build, optionalVisual]),
        evidence: [
            binding(receipt: "r-build", requirement: build, authority: .buildSystem),
            binding(receipt: "r-optional-fail", requirement: optionalVisual, authority: .visualQA, outcome: .failed),
        ],
        defects: [],
        knownLimitations: []
    )
    #expect(projection.state == .complete)
    #expect(projection.failedRequirementIDs.isEmpty)
}

@Test func staleLimitationAcceptanceFailsClosed() throws {
    let build = requirement("build", .build)
    let limitation = try ForgeCompletionKnownLimitation(
        id: id("stale-lim"),
        projectID: projectID,
        sourceRevision: sourceRevision,
        missionID: missionID,
        constitutionRevision: 6,
        summary: "Accepted against an older definition of done.",
        acceptedReceiptID: id("old-accept")
    )
    #expect(throws: ForgeCompletionValidationError.identityMismatch("limitation:stale-lim")) {
        try ForgeCompletionEvaluator.evaluate(
            constitution: constitution(requirements: [build]),
            evidence: [binding(receipt: "r-build", requirement: build, authority: .buildSystem)],
            defects: [],
            knownLimitations: [limitation]
        )
    }
}

@Test func archiveRoundTripRevalidatesAndPreservesProjection() throws {
    let build = requirement("build", .build)
    let contract = constitution(requirements: [build])
    let archive = try ForgeCompletionArchive(
        constitution: contract,
        evidence: [binding(receipt: "r-build", requirement: build, authority: .buildSystem)],
        defects: [],
        knownLimitations: []
    )

    let data = try JSONEncoder().encode(archive)
    let decoded = try JSONDecoder().decode(ForgeCompletionArchive.self, from: data)
    #expect(try decoded.projection().state == .complete)
}

@Test func archiveRejectsFutureSchema() throws {
    let build = requirement("build", .build)
    let archive = try ForgeCompletionArchive(
        constitution: constitution(requirements: [build]),
        evidence: [binding(receipt: "r-build", requirement: build, authority: .buildSystem)],
        defects: [],
        knownLimitations: []
    )
    let data = try JSONEncoder().encode(archive)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 99
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ForgeCompletionArchive.self, from: tampered)
    }
}

@Test func constitutionDecodeRejectsDuplicateRequirementIDs() throws {
    let build = requirement("same", .build)
    let contract = constitution(requirements: [build])
    let data = try JSONEncoder().encode(contract)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let reqs = try #require(object["requirements"] as? [[String: Any]])
    object["requirements"] = [reqs[0], reqs[0]]
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ForgeCompletionConstitution.self, from: tampered)
    }
}

@Test func limitationDecodeRejectsWhitespaceSummary() throws {
    let limitation = try ForgeCompletionKnownLimitation(
        id: id("lim"),
        projectID: projectID,
        sourceRevision: sourceRevision,
        missionID: missionID,
        constitutionRevision: 7,
        summary: "A real accepted limitation.",
        acceptedReceiptID: id("accept-lim")
    )
    let data = try JSONEncoder().encode(limitation)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["summary"] = "   \n "
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ForgeCompletionKnownLimitation.self, from: tampered)
    }
}

@Test func deterministicProjectionOrderingDoesNotDependOnInputOrder() throws {
    let launch = requirement("z-launch", .launch)
    let build = requirement("a-build", .build)
    let contract = constitution(requirements: [launch, build])
    let evidence = [
        binding(receipt: "z-receipt", requirement: launch, authority: .runtimeHost),
        binding(receipt: "a-receipt", requirement: build, authority: .buildSystem),
    ]
    let first = try ForgeCompletionEvaluator.evaluate(
        constitution: contract,
        evidence: evidence,
        defects: [],
        knownLimitations: []
    )
    let second = try ForgeCompletionEvaluator.evaluate(
        constitution: contract,
        evidence: Array(evidence.reversed()),
        defects: [],
        knownLimitations: []
    )

    #expect(first == second)
    #expect(first.satisfiedRequirementIDs == [build.id, launch.id])
    #expect(first.acceptedEvidenceReceiptIDs == [id("a-receipt"), id("z-receipt")])
}
