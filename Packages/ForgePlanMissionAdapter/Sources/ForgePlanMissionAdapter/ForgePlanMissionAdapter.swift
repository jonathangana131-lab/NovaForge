import Foundation
import ForgePlanCore

public enum ForgePlanMissionHandoffError: Error, Equatable, Sendable {
    case invalidContext(String)
    case invalidSourceBinding(String)
    case invalidSummary(String)
    case duplicateDecisionID(String)
    case invalidDecision(String)
    case invalidPlanQuestion(String)
    case invalidAcceptedPlan(String)
}

private func canonicalOpaqueID(
    _ value: String,
    field: String,
    error: (String) -> ForgePlanMissionHandoffError
) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value == trimmed,
          !value.isEmpty,
          value.utf8.count <= 512,
          value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
        throw error(field)
    }
    return value
}

private func validText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
        && value.utf8.count <= maximumUTF8Bytes
        && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" || $0 == "\r"
        }
}

private func validOptionalText(_ value: String?, maximumUTF8Bytes: Int) -> Bool {
    guard let value else { return true }
    return value.utf8.count <= maximumUTF8Bytes
        && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" || $0 == "\r"
        }
}

/// Host-supplied identity for this Plan -> Mission handoff candidate.
///
/// The acceptance reference is deliberately opaque. It is not evidence that the plan was accepted;
/// the eventual accepted-plan authority must verify that this exact reference binds the complete
/// `ForgePlanMissionAcceptedPlanSubject` carried by the handoff.
public struct ForgePlanMissionContext: Hashable, Sendable {
    public let handoffRevision: UInt64
    public let planAcceptanceReceiptID: String

    public init(
        handoffRevision: UInt64,
        planAcceptanceReceiptID: String
    ) throws {
        guard handoffRevision > 0 else {
            throw ForgePlanMissionHandoffError.invalidContext("handoffRevision")
        }
        self.handoffRevision = handoffRevision
        self.planAcceptanceReceiptID = try canonicalOpaqueID(
            planAcceptanceReceiptID,
            field: "planAcceptanceReceiptID",
            error: ForgePlanMissionHandoffError.invalidContext
        )
    }
}

/// Composer/Plan revision identity for this candidate handoff.
///
/// These positive values are not freshness proof. The eventual accepted-plan store must compare them
/// against its current accepted Composer draft + Plan record. This is intentionally named separately
/// from generated-project/source revision, which does not exist yet at this boundary.
public struct ForgePlanMissionSourceBinding: Hashable, Sendable {
    public let composerDraftRevision: UInt64
    public let planRevision: UInt64
    public let planReferenceID: String

    public init(
        composerDraftRevision: UInt64,
        planRevision: UInt64,
        planReferenceID: String
    ) throws {
        guard composerDraftRevision > 0 else {
            throw ForgePlanMissionHandoffError.invalidSourceBinding("composerDraftRevision")
        }
        guard planRevision > 0 else {
            throw ForgePlanMissionHandoffError.invalidSourceBinding("planRevision")
        }
        self.composerDraftRevision = composerDraftRevision
        self.planRevision = planRevision
        self.planReferenceID = try canonicalOpaqueID(
            planReferenceID,
            field: "planReferenceID",
            error: ForgePlanMissionHandoffError.invalidSourceBinding
        )
    }
}

/// Canonical answer material retained as part of the exact accepted Plan subject.
///
/// This is candidate data, not an acceptance receipt. Ordering is canonicalized by question id so a
/// downstream verifier can compare one exact subject rather than independently supplied summary text.
public struct ForgePlanMissionAcceptedAnswer: Hashable, Sendable {
    public let questionID: String
    public let answer: PlanAnswer

    fileprivate init(questionID: String, answer: PlanAnswer) {
        self.questionID = questionID
        self.answer = answer
    }
}

/// Complete candidate subject that an opaque Plan acceptance reference must bind.
///
/// The subject keeps the full Plan proposal (including question schemas), exact presented answers,
/// derived ready summary, and Composer/Plan revision identity together. Its initializer is not public:
/// ordinary callers can ask the adapter to derive a candidate subject from PlanCore values, but cannot
/// independently pair arbitrary summary fields into a different subject shape.
///
/// This remains non-Codable and non-authorizing. A future canonical Plan store/host must authenticate
/// the receipt/reference against this entire value before Mission-era policy can trust it.
public struct ForgePlanMissionAcceptedPlanSubject: Hashable, Sendable {
    public let proposal: PlanSpaceProposal
    public let acceptedAnswers: [ForgePlanMissionAcceptedAnswer]
    public let summary: ReadyToForgeSummary
    public let composerPlanBinding: ForgePlanMissionSourceBinding

    fileprivate init(
        proposal: PlanSpaceProposal,
        acceptedAnswers: [ForgePlanMissionAcceptedAnswer],
        summary: ReadyToForgeSummary,
        composerPlanBinding: ForgePlanMissionSourceBinding
    ) {
        self.proposal = proposal
        self.acceptedAnswers = acceptedAnswers
        self.summary = summary
        self.composerPlanBinding = composerPlanBinding
    }
}

/// Exact Plan question contract that must govern a delegated `Decide for me` resolution.
///
/// The future resolver must produce a concrete value accepted by this question. Calling
/// `acceptsConcreteResolution` is only schema validation; it does not authenticate who chose the value.
public struct ForgePlanMissionDelegatedDecisionContract: Hashable, Sendable {
    public let decisionID: String
    public let question: PlanQuestion

    fileprivate init(question: PlanQuestion) {
        self.decisionID = question.id
        self.question = question
    }

    public func acceptsConcreteResolution(_ answer: PlanAnswer) -> Bool {
        if case .decideForMe = answer {
            return false
        }
        return question.accepts(answer)
    }
}

/// Control truth that must survive into Mission-era policy instead of being flattened into #110's
/// currently narrower Constitution.
///
/// This is a candidate persistence/binding requirement, not Mission authority. The eventual Mission
/// adapter must bind the entire envelope to the exact accepted Mission/Constitution revision and
/// enforce it on routing/work leases.
public struct ForgePlanMissionControlEnvelope: Hashable, Sendable {
    public let handoffRevision: UInt64
    public let acceptedPlanSubject: ForgePlanMissionAcceptedPlanSubject
    public let controlProfile: ForgeComposerV14ControlProfile
    public let delegatedDecisionContracts: [ForgePlanMissionDelegatedDecisionContract]

    fileprivate init(
        handoffRevision: UInt64,
        acceptedPlanSubject: ForgePlanMissionAcceptedPlanSubject,
        controlProfile: ForgeComposerV14ControlProfile,
        delegatedDecisionContracts: [ForgePlanMissionDelegatedDecisionContract]
    ) {
        self.handoffRevision = handoffRevision
        self.acceptedPlanSubject = acceptedPlanSubject
        self.controlProfile = controlProfile
        self.delegatedDecisionContracts = delegatedDecisionContracts
    }
}

/// Requirements for the eventual host/Mission router. These values are never evidence that the
/// requirement has already been satisfied.
public enum ForgePlanMissionExecutionPrecondition: Hashable, Sendable {
    /// Compare against the current accepted Composer/Plan store. This is not generated source revision.
    case composerPlanRevisionMatch(binding: ForgePlanMissionSourceBinding)
    /// Authenticate this receipt/reference against the *entire* accepted Plan subject, not ID presence.
    case acceptedPlanSubjectVerification(
        receiptID: String,
        subject: ForgePlanMissionAcceptedPlanSubject
    )
    /// Persist/bind the exact typed control envelope to the future Mission/Constitution revision.
    case missionControlEnvelopeBinding(envelope: ForgePlanMissionControlEnvelope)
    case localOnlyRouting
    case providerAllowlistEnforcement(providerIDs: [String])
    case autonomyPolicyResolution(intent: ForgeComposerAutonomyIntent)
    case explicitModelQualification(referenceID: String)
    /// Resolve against the exact original Plan question schema.
    case delegatedDecisionResolution(contract: ForgePlanMissionDelegatedDecisionContract)
}

/// Typed Plan Space output that can survive the presentation boundary without flattening privacy,
/// model selection, autonomy, build-depth, creativity, refactor risk, or decisions into prompt prose.
///
/// This is intentionally *not* a Mission Constitution or execution authority. Canonical Mission
/// types are owned by the Mission Engine lineage; after that authority lands, a separate adapter must
/// authenticate `acceptedPlanSubject`, bind `controlEnvelope` to the same Mission revision, and then
/// enforce every remaining precondition. The current #110 Constitution is not sufficient by itself.
public struct ForgePlanMissionHandoff: Sendable {
    public let revision: UInt64
    public let acceptedPlanSubject: ForgePlanMissionAcceptedPlanSubject
    public let intentSummary: String
    public let planAcceptanceReceiptID: String
    public let planDecisions: [PlanResolvedDecision]
    public let controlProfile: ForgeComposerV14ControlProfile
    public let sourceBinding: ForgePlanMissionSourceBinding
    public let controlEnvelope: ForgePlanMissionControlEnvelope
    public let executionPreconditions: [ForgePlanMissionExecutionPrecondition]

    public var authorizesExecution: Bool { false }

    fileprivate init(
        revision: UInt64,
        acceptedPlanSubject: ForgePlanMissionAcceptedPlanSubject,
        intentSummary: String,
        planAcceptanceReceiptID: String,
        planDecisions: [PlanResolvedDecision],
        controlProfile: ForgeComposerV14ControlProfile,
        sourceBinding: ForgePlanMissionSourceBinding,
        controlEnvelope: ForgePlanMissionControlEnvelope,
        executionPreconditions: [ForgePlanMissionExecutionPrecondition]
    ) {
        self.revision = revision
        self.acceptedPlanSubject = acceptedPlanSubject
        self.intentSummary = intentSummary
        self.planAcceptanceReceiptID = planAcceptanceReceiptID
        self.planDecisions = planDecisions
        self.controlProfile = controlProfile
        self.sourceBinding = sourceBinding
        self.controlEnvelope = controlEnvelope
        self.executionPreconditions = executionPreconditions
    }

    public var delegatedDecisionContracts: [ForgePlanMissionDelegatedDecisionContract] {
        controlEnvelope.delegatedDecisionContracts
    }

    public var delegatedDecisionIDs: [String] {
        delegatedDecisionContracts.map(\.decisionID)
    }

    public var requiresDelegatedDecisionResolution: Bool {
        !delegatedDecisionIDs.isEmpty
    }

    public var requiresExternalModelQualification: Bool {
        executionPreconditions.contains { precondition in
            if case .explicitModelQualification = precondition { return true }
            return false
        }
    }

    public var requestedExplicitModelReferenceID: String? {
        executionPreconditions.compactMap { precondition -> String? in
            guard case .explicitModelQualification(let referenceID) = precondition else { return nil }
            return referenceID
        }.first
    }

    public var privacyIntent: ForgeComposerPrivacyIntent { controlProfile.privacy }
    public var autonomyIntent: ForgeComposerAutonomyIntent { controlProfile.autonomy }
}

public enum ForgePlanMissionAdapter {
    /// Derive one candidate handoff from the exact Plan proposal and its exact presented answers.
    ///
    /// A free-floating `ReadyToForgeSummary` is deliberately not accepted here. PlanCore derives the
    /// summary from the same proposal + answers whose complete question contracts are retained in the
    /// accepted subject. The opaque acceptance reference is then required to authenticate that whole
    /// subject downstream.
    public static func makeHandoff(
        proposal: PlanSpaceProposal,
        answers: [String: PlanAnswer],
        context: ForgePlanMissionContext,
        sourceBinding: ForgePlanMissionSourceBinding
    ) throws -> ForgePlanMissionHandoff {
        try validate(proposal: proposal, answers: answers)

        guard let derivedSummary = proposal.readySummary(answers: answers) else {
            throw ForgePlanMissionHandoffError.invalidAcceptedPlan("proposalNotReady")
        }
        try validate(summary: derivedSummary)

        let canonicalDecisions = derivedSummary.decisions.sorted { lhs, rhs in
            lhs.id == rhs.id ? lhs.prompt < rhs.prompt : lhs.id < rhs.id
        }
        let canonicalSummary = ReadyToForgeSummary(
            intentSummary: derivedSummary.intentSummary,
            decisions: canonicalDecisions,
            controls: derivedSummary.controls
        )
        let acceptedAnswers = answers.keys.sorted().compactMap { questionID -> ForgePlanMissionAcceptedAnswer? in
            guard let answer = answers[questionID] else { return nil }
            return ForgePlanMissionAcceptedAnswer(questionID: questionID, answer: answer)
        }
        let acceptedSubject = ForgePlanMissionAcceptedPlanSubject(
            proposal: proposal,
            acceptedAnswers: acceptedAnswers,
            summary: canonicalSummary,
            composerPlanBinding: sourceBinding
        )

        let presentedQuestionsByID = Dictionary(
            uniqueKeysWithValues: proposal.presentedQuestions.map { ($0.id, $0) }
        )
        let delegatedContracts = canonicalDecisions.compactMap { decision -> ForgePlanMissionDelegatedDecisionContract? in
            guard decision.value == .delegatedToNovaForge,
                  let question = presentedQuestionsByID[decision.id]
            else {
                return nil
            }
            return ForgePlanMissionDelegatedDecisionContract(question: question)
        }

        let controlEnvelope = ForgePlanMissionControlEnvelope(
            handoffRevision: context.handoffRevision,
            acceptedPlanSubject: acceptedSubject,
            controlProfile: canonicalSummary.controls,
            delegatedDecisionContracts: delegatedContracts
        )

        var preconditions: [ForgePlanMissionExecutionPrecondition] = [
            .composerPlanRevisionMatch(binding: sourceBinding),
            .acceptedPlanSubjectVerification(
                receiptID: context.planAcceptanceReceiptID,
                subject: acceptedSubject
            ),
            .missionControlEnvelopeBinding(envelope: controlEnvelope),
        ]

        switch canonicalSummary.controls.privacy {
        case .localOnly:
            preconditions.append(.localOnlyRouting)
        case .providerAllowlist(let providerIDs):
            preconditions.append(.providerAllowlistEnforcement(providerIDs: providerIDs))
        }

        preconditions.append(
            .autonomyPolicyResolution(intent: canonicalSummary.controls.autonomy)
        )

        if case .explicitModel(let referenceID) = canonicalSummary.controls.intelligence {
            preconditions.append(.explicitModelQualification(referenceID: referenceID))
        }

        preconditions.append(contentsOf: delegatedContracts.map {
            .delegatedDecisionResolution(contract: $0)
        })

        return ForgePlanMissionHandoff(
            revision: context.handoffRevision,
            acceptedPlanSubject: acceptedSubject,
            intentSummary: canonicalSummary.intentSummary,
            planAcceptanceReceiptID: context.planAcceptanceReceiptID,
            planDecisions: canonicalDecisions,
            controlProfile: canonicalSummary.controls,
            sourceBinding: sourceBinding,
            controlEnvelope: controlEnvelope,
            executionPreconditions: preconditions
        )
    }

    private static func validate(
        proposal: PlanSpaceProposal,
        answers: [String: PlanAnswer]
    ) throws {
        guard validText(proposal.intentSummary, maximumUTF8Bytes: 16_384) else {
            throw ForgePlanMissionHandoffError.invalidSummary("intentSummary")
        }
        guard proposal.questions.count <= 128 else {
            throw ForgePlanMissionHandoffError.invalidSummary("tooManyQuestions")
        }

        var questionIDs = Set<String>()
        for question in proposal.questions {
            try validate(question: question)
            guard questionIDs.insert(question.id).inserted else {
                throw ForgePlanMissionHandoffError.invalidPlanQuestion(question.id)
            }
        }

        let presentedIDs = Set(proposal.presentedQuestions.map(\.id))
        guard Set(answers.keys) == presentedIDs else {
            throw ForgePlanMissionHandoffError.invalidAcceptedPlan("presentedAnswerSet")
        }
        guard proposal.schemaValidationIssues.isEmpty else {
            throw ForgePlanMissionHandoffError.invalidAcceptedPlan("proposalSchema")
        }
        guard proposal.validationIssues(answers: answers).isEmpty else {
            throw ForgePlanMissionHandoffError.invalidAcceptedPlan("answers")
        }
    }

    private static func validate(question: PlanQuestion) throws {
        let id = question.id
        guard id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              id.utf8.count <= 512,
              id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              validText(question.prompt, maximumUTF8Bytes: 4_096),
              validOptionalText(question.reason, maximumUTF8Bytes: 4_096),
              validOptionalText(question.placeholder, maximumUTF8Bytes: 4_096),
              question.options.count <= 64,
              question.validationIssues.isEmpty
        else {
            throw ForgePlanMissionHandoffError.invalidPlanQuestion(id)
        }

        var optionIDs = Set<String>()
        for option in question.options {
            let optionID = option.id
            guard optionID == optionID.trimmingCharacters(in: .whitespacesAndNewlines),
                  !optionID.isEmpty,
                  optionID.utf8.count <= 512,
                  optionID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  optionIDs.insert(optionID).inserted,
                  validText(option.label, maximumUTF8Bytes: 4_096),
                  validOptionalText(option.detail, maximumUTF8Bytes: 4_096),
                  validOptionalText(option.previewToken, maximumUTF8Bytes: 1_024)
            else {
                throw ForgePlanMissionHandoffError.invalidPlanQuestion(id)
            }
        }

        if let range = question.range, !range.isValid {
            throw ForgePlanMissionHandoffError.invalidPlanQuestion(id)
        }
    }

    private static func validate(summary: ReadyToForgeSummary) throws {
        guard validText(summary.intentSummary, maximumUTF8Bytes: 16_384) else {
            throw ForgePlanMissionHandoffError.invalidSummary("intentSummary")
        }
        guard summary.decisions.count <= 128 else {
            throw ForgePlanMissionHandoffError.invalidSummary("tooManyDecisions")
        }

        var ids = Set<String>()
        for decision in summary.decisions {
            let id = decision.id
            guard id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  id.utf8.count <= 512,
                  id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else {
                throw ForgePlanMissionHandoffError.invalidDecision(id)
            }
            guard ids.insert(id).inserted else {
                throw ForgePlanMissionHandoffError.duplicateDecisionID(id)
            }
            guard validText(decision.prompt, maximumUTF8Bytes: 4_096) else {
                throw ForgePlanMissionHandoffError.invalidDecision(id)
            }

            switch decision.value {
            case .selected(let optionID, let label):
                guard optionID == optionID.trimmingCharacters(in: .whitespacesAndNewlines),
                      !optionID.isEmpty,
                      optionID.utf8.count <= 512,
                      optionID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                      validText(label, maximumUTF8Bytes: 4_096)
                else {
                    throw ForgePlanMissionHandoffError.invalidDecision(id)
                }
            case .scalar(let value):
                guard value.isFinite else {
                    throw ForgePlanMissionHandoffError.invalidDecision(id)
                }
            case .interval(let lower, let upper):
                guard lower.isFinite, upper.isFinite, lower <= upper else {
                    throw ForgePlanMissionHandoffError.invalidDecision(id)
                }
            case .text(let value):
                guard validText(value, maximumUTF8Bytes: 8_192) else {
                    throw ForgePlanMissionHandoffError.invalidDecision(id)
                }
            case .delegatedToNovaForge:
                break
            }
        }
    }
}
