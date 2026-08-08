import Foundation

public enum ForgeIntelligence: String, CaseIterable, Codable, Sendable {
    case fast
    case balanced
    case deep
    case extreme

    public var orchestrationDepth: ForgeOrchestrationDepth {
        switch self {
        case .fast: .lean
        case .balanced: .standard
        case .deep: .deep
        case .extreme: .extreme
        }
    }

    /// A normalized preference only. Provider adapters remain responsible for
    /// mapping this value to a documented native reasoning control when one exists.
    public var nativeReasoningPreference: Double {
        switch self {
        case .fast: 0.15
        case .balanced: 0.45
        case .deep: 0.75
        case .extreme: 1.0
        }
    }

    public func resolve(providerCapabilities: ProviderReasoningCapabilities) -> ForgeIntelligenceResolution {
        ForgeIntelligenceResolution(
            orchestrationDepth: orchestrationDepth,
            nativeReasoningPreference: providerCapabilities.supportsNativeReasoning
                ? nativeReasoningPreference
                : nil
        )
    }
}

public enum ForgeOrchestrationDepth: String, Codable, Sendable {
    case lean
    case standard
    case deep
    case extreme
}

public struct ProviderReasoningCapabilities: Hashable, Codable, Sendable {
    public var supportsNativeReasoning: Bool

    public init(supportsNativeReasoning: Bool) {
        self.supportsNativeReasoning = supportsNativeReasoning
    }
}

public struct ForgeIntelligenceResolution: Hashable, Codable, Sendable {
    public var orchestrationDepth: ForgeOrchestrationDepth
    public var nativeReasoningPreference: Double?

    public init(orchestrationDepth: ForgeOrchestrationDepth, nativeReasoningPreference: Double?) {
        self.orchestrationDepth = orchestrationDepth
        self.nativeReasoningPreference = nativeReasoningPreference
    }
}

public enum ForgeBuildDepth: String, CaseIterable, Codable, Sendable {
    case prototype
    case polished
    case obsessive
}

/// User intent for how proactively NovaForge may proceed. This value is never
/// an execution authorization; the policy/approval layer remains authoritative.
public enum ForgeAutonomy: String, CaseIterable, Codable, Sendable {
    case ask
    case assist
    case build
    case autopilot
}

public struct NormalizedForgeControl: Hashable, Codable, Sendable {
    public let value: Double

    private enum CodingKeys: String, CodingKey {
        case value
    }

    public init(_ value: Double) {
        self.value = value.isFinite ? min(max(value, 0), 1) : 0.5
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode(Double.self, forKey: .value))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

/// Legacy V13 compatibility shape only. Canonical V14 Composer/Plan Space state uses
/// `ForgeComposerV14ControlProfile`; this legacy profile no longer flows through
/// `PlanSpaceProposal` or `ReadyToForgeSummary`.
public struct ForgeControlProfile: Hashable, Codable, Sendable {
    public var intelligence: ForgeIntelligence
    public var buildDepth: ForgeBuildDepth
    public var creativity: NormalizedForgeControl
    public var refactorRisk: NormalizedForgeControl
    public var autonomy: ForgeAutonomy
    public var localCompute: NormalizedForgeControl
    public var cloudResource: NormalizedForgeControl

    public init(
        intelligence: ForgeIntelligence = .balanced,
        buildDepth: ForgeBuildDepth = .polished,
        creativity: NormalizedForgeControl = .init(0.45),
        refactorRisk: NormalizedForgeControl = .init(0.25),
        autonomy: ForgeAutonomy = .assist,
        localCompute: NormalizedForgeControl = .init(0.45),
        cloudResource: NormalizedForgeControl = .init(0.45)
    ) {
        self.intelligence = intelligence
        self.buildDepth = buildDepth
        self.creativity = creativity
        self.refactorRisk = refactorRisk
        self.autonomy = autonomy
        self.localCompute = localCompute
        self.cloudResource = cloudResource
    }
}

public enum PlanQuestionImportance: String, Codable, Sendable {
    case required
    case material
    case inferable

    public var requiresUserSurface: Bool {
        self != .inferable
    }
}

public enum PlanQuestionControlKind: String, Codable, Sendable {
    case segmentedChoice
    case slider
    case range
    case orientation
    case imageReference
    case visualVariant
    case freeText

    fileprivate var usesChoices: Bool {
        switch self {
        case .segmentedChoice, .orientation, .imageReference, .visualVariant: true
        case .slider, .range, .freeText: false
        }
    }
}

public struct PlanOption: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var label: String
    public var detail: String?
    public var previewToken: String?

    public init(id: String, label: String, detail: String? = nil, previewToken: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.previewToken = previewToken
    }
}

public struct PlanRangeSpec: Hashable, Codable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var step: Double?
    public var lowLabel: String?
    public var highLabel: String?

    public init(
        minimum: Double,
        maximum: Double,
        step: Double? = nil,
        lowLabel: String? = nil,
        highLabel: String? = nil
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.lowLabel = lowLabel
        self.highLabel = highLabel
    }

    public var isValid: Bool {
        guard minimum.isFinite, maximum.isFinite, minimum < maximum else { return false }
        guard let step else { return true }
        let span = maximum - minimum
        guard step.isFinite, step > 0, step <= span else { return false }
        let stepsAcrossRange = span / step
        return abs(stepsAcrossRange - stepsAcrossRange.rounded()) < 1e-9
    }

    public func contains(_ value: Double) -> Bool {
        value.isFinite && value >= minimum && value <= maximum
    }

    public func accepts(_ value: Double) -> Bool {
        guard contains(value) else { return false }
        guard let step else { return true }
        let stepsFromMinimum = (value - minimum) / step
        return abs(stepsFromMinimum - stepsFromMinimum.rounded()) < 1e-9
    }
}

public struct PlanQuestion: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var prompt: String
    public var reason: String?
    public var importance: PlanQuestionImportance
    public var controlKind: PlanQuestionControlKind
    public var options: [PlanOption]
    public var range: PlanRangeSpec?
    public var placeholder: String?
    public var allowsDecideForMe: Bool

    public init(
        id: String,
        prompt: String,
        reason: String? = nil,
        importance: PlanQuestionImportance = .material,
        controlKind: PlanQuestionControlKind,
        options: [PlanOption] = [],
        range: PlanRangeSpec? = nil,
        placeholder: String? = nil,
        allowsDecideForMe: Bool = true
    ) {
        self.id = id
        self.prompt = prompt
        self.reason = reason
        self.importance = importance
        self.controlKind = controlKind
        self.options = options
        self.range = range
        self.placeholder = placeholder
        self.allowsDecideForMe = allowsDecideForMe
    }

    public var validationIssues: [PlanValidationIssue] {
        var issues: [PlanValidationIssue] = []

        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.invalidQuestion(questionID: id, reason: "Question id must not be empty."))
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.invalidQuestion(questionID: id, reason: "Question prompt must not be empty."))
        }

        let optionIDs = options.map(\.id)
        if Set(optionIDs).count != optionIDs.count {
            issues.append(.invalidQuestion(questionID: id, reason: "Question option ids must be unique."))
        }
        if options.contains(where: { $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.append(.invalidQuestion(questionID: id, reason: "Question option ids must not be empty."))
        }
        if options.contains(where: { $0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.append(.invalidQuestion(questionID: id, reason: "Question option labels must not be empty."))
        }

        if controlKind.usesChoices {
            if options.count < 2 {
                issues.append(.invalidQuestion(questionID: id, reason: "Choice controls require at least two options."))
            }
            if range != nil {
                issues.append(.invalidQuestion(questionID: id, reason: "Choice controls cannot also define a numeric range."))
            }
        } else {
            if !options.isEmpty {
                issues.append(.invalidQuestion(questionID: id, reason: "This control kind cannot define choice options."))
            }
            switch controlKind {
            case .slider, .range:
                if range?.isValid != true {
                    issues.append(.invalidQuestion(questionID: id, reason: "Numeric controls require a valid range."))
                }
            case .freeText:
                if range != nil {
                    issues.append(.invalidQuestion(questionID: id, reason: "Free text controls cannot define a numeric range."))
                }
            case .segmentedChoice, .orientation, .imageReference, .visualVariant:
                break
            }
        }

        return issues
    }

    public func accepts(_ answer: PlanAnswer) -> Bool {
        if case .decideForMe = answer {
            return allowsDecideForMe
        }

        switch (controlKind, answer) {
        case (.segmentedChoice, .choice(let id)),
             (.orientation, .choice(let id)),
             (.imageReference, .choice(let id)),
             (.visualVariant, .choice(let id)):
            return options.contains { $0.id == id }

        case (.slider, .scalar(let value)):
            return range?.accepts(value) == true

        case (.range, .interval(let lower, let upper)):
            guard lower <= upper, let range else { return false }
            return range.accepts(lower) && range.accepts(upper)

        case (.freeText, .text(let value)):
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        default:
            return false
        }
    }
}

public enum PlanAnswer: Hashable, Codable, Sendable {
    case choice(String)
    case scalar(Double)
    case interval(lower: Double, upper: Double)
    case text(String)
    case decideForMe

    private enum CodingKeys: String, CodingKey {
        case type
        case choice
        case scalar
        case lower
        case upper
        case text
    }

    private enum Kind: String, Codable {
        case choice
        case scalar
        case interval
        case text
        case decideForMe
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .choice:
            self = .choice(try container.decode(String.self, forKey: .choice))
        case .scalar:
            self = .scalar(try container.decode(Double.self, forKey: .scalar))
        case .interval:
            self = .interval(
                lower: try container.decode(Double.self, forKey: .lower),
                upper: try container.decode(Double.self, forKey: .upper)
            )
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .decideForMe:
            self = .decideForMe
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .choice(let id):
            try container.encode(Kind.choice, forKey: .type)
            try container.encode(id, forKey: .choice)
        case .scalar(let value):
            try container.encode(Kind.scalar, forKey: .type)
            try container.encode(value, forKey: .scalar)
        case .interval(let lower, let upper):
            try container.encode(Kind.interval, forKey: .type)
            try container.encode(lower, forKey: .lower)
            try container.encode(upper, forKey: .upper)
        case .text(let value):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case .decideForMe:
            try container.encode(Kind.decideForMe, forKey: .type)
        }
    }
}

public enum PlanValidationIssue: Hashable, Codable, Sendable {
    case invalidProposal(reason: String)
    case duplicateQuestionID(String)
    case invalidQuestion(questionID: String, reason: String)
    case missingAnswer(questionID: String)
    case invalidAnswer(questionID: String)
}

public enum PlanDecisionValue: Hashable, Codable, Sendable {
    case selected(optionID: String, label: String)
    case scalar(Double)
    case interval(lower: Double, upper: Double)
    case text(String)
    case delegatedToNovaForge
}

public struct PlanResolvedDecision: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var prompt: String
    public var value: PlanDecisionValue

    public init(id: String, prompt: String, value: PlanDecisionValue) {
        self.id = id
        self.prompt = prompt
        self.value = value
    }
}

public struct ReadyToForgeSummary: Hashable, Codable, Sendable {
    public var intentSummary: String
    public var decisions: [PlanResolvedDecision]
    public var controls: ForgeComposerV14ControlProfile

    public init(
        intentSummary: String,
        decisions: [PlanResolvedDecision],
        controls: ForgeComposerV14ControlProfile
    ) {
        self.intentSummary = intentSummary
        self.decisions = decisions
        self.controls = controls
    }

    /// Delegation makes Plan Space complete, but it does not invent the delegated
    /// semantic choice. The authoritative Mission Engine must resolve and receipt
    /// each of these decisions before execution can rely on it.
    public var delegatedDecisionIDs: [String] {
        decisions.compactMap { decision in
            decision.value == .delegatedToNovaForge ? decision.id : nil
        }
    }

    public var requiresMissionResolution: Bool {
        !delegatedDecisionIDs.isEmpty
    }
}

public struct PlanSpaceProposal: Hashable, Codable, Sendable {
    public var intentSummary: String
    public var questions: [PlanQuestion]
    public var controls: ForgeComposerV14ControlProfile

    public init(
        intentSummary: String,
        questions: [PlanQuestion],
        controls: ForgeComposerV14ControlProfile = .init()
    ) {
        self.intentSummary = intentSummary
        self.questions = questions
        self.controls = controls
    }

    /// Inferable questions intentionally stay off the primary Plan Space surface.
    public var presentedQuestions: [PlanQuestion] {
        questions.filter { $0.importance.requiresUserSurface }
    }

    public var schemaValidationIssues: [PlanValidationIssue] {
        var issues = questions.flatMap(\.validationIssues)
        if intentSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.invalidProposal(reason: "Intent summary must not be empty."))
        }
        let ids = questions.map(\.id)
        let duplicateIDs = Dictionary(grouping: ids, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        issues.append(contentsOf: duplicateIDs.map(PlanValidationIssue.duplicateQuestionID))
        return issues
    }

    public func validationIssues(answers: [String: PlanAnswer]) -> [PlanValidationIssue] {
        var issues = schemaValidationIssues

        for question in presentedQuestions {
            guard let answer = answers[question.id] else {
                issues.append(.missingAnswer(questionID: question.id))
                continue
            }
            if !question.accepts(answer) {
                issues.append(.invalidAnswer(questionID: question.id))
            }
        }

        return issues
    }

    public func unresolvedQuestionIDs(answers: [String: PlanAnswer]) -> [String] {
        presentedQuestions.compactMap { question in
            guard let answer = answers[question.id], question.accepts(answer) else {
                return question.id
            }
            return nil
        }
    }

    /// Ready means the user's Plan Space interaction can hand off to the durable
    /// Mission Engine. It is not execution authorization; delegated decisions may
    /// still require a concrete, receipted Mission Constitution choice.
    public func isReadyToForge(answers: [String: PlanAnswer]) -> Bool {
        schemaValidationIssues.isEmpty && unresolvedQuestionIDs(answers: answers).isEmpty
    }

    public func readySummary(answers: [String: PlanAnswer]) -> ReadyToForgeSummary? {
        guard isReadyToForge(answers: answers) else { return nil }

        let decisions = presentedQuestions.compactMap { question -> PlanResolvedDecision? in
            guard let answer = answers[question.id] else { return nil }

            let value: PlanDecisionValue
            switch answer {
            case .choice(let optionID):
                guard let option = question.options.first(where: { $0.id == optionID }) else { return nil }
                value = .selected(optionID: option.id, label: option.label)
            case .scalar(let scalar):
                value = .scalar(scalar)
            case .interval(let lower, let upper):
                value = .interval(lower: lower, upper: upper)
            case .text(let text):
                value = .text(text)
            case .decideForMe:
                value = .delegatedToNovaForge
            }

            return PlanResolvedDecision(id: question.id, prompt: question.prompt, value: value)
        }

        guard decisions.count == presentedQuestions.count else { return nil }
        return ReadyToForgeSummary(intentSummary: intentSummary, decisions: decisions, controls: controls)
    }
}

public enum ForgePulseState: String, CaseIterable, Codable, Sendable {
    case understanding
    case planning
    case editing
    case running
    case inspecting
    case fixing
    case polishing
    case waitingForDecision
    case complete
}

public enum ForgePrimaryAction: String, Codable, Sendable {
    case send
    case plan
    case forge
    case pause
    case resume
    case run
}

/// Presentation-only state. The durable Mission Engine remains the authority for
/// actual mission lifecycle, cancellation, recovery, and execution permissions.
public enum ForgePrimaryActionState: Hashable, Codable, Sendable {
    case composing
    case waitingForPlanDecision
    case readyToForge
    case missionRunning
    case missionPaused
    case missionComplete(runnable: Bool)

    public var primaryAction: ForgePrimaryAction {
        switch self {
        case .composing: .send
        case .waitingForPlanDecision: .plan
        case .readyToForge: .forge
        case .missionRunning: .pause
        case .missionPaused: .resume
        case .missionComplete(let runnable): runnable ? .run : .forge
        }
    }
}
