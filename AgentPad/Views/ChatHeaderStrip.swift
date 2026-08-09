//
//  ChatHeaderStrip.swift
//  NovaForge
//
//  The retired double-deck chat header stays retired. V14 reuses this already
//  registered source slot for the creation-first Plan Space presentation layer.
//  ForgePlanCore remains the only planning/control authority.
//

import Foundation
import ForgePlanCore
import SwiftUI
import UIKit

// MARK: - Plan Space presentation adapter

/// Presentation-only helpers around canonical ForgePlanCore state.
///
/// The normal composer path intentionally invents no material questions. A
/// planner/mission adapter may supply them later, but the UI never manufactures
/// product decisions merely to make Plan Space look busy.
enum ForgePlanSpacePresentation {
    static let debugLaunchArgument = "--forge-plan-space-demo"

    static func proposal(intent: String) -> PlanSpaceProposal {
        PlanSpaceProposal(
            intentSummary: intent.trimmingCharacters(in: .whitespacesAndNewlines),
            questions: [],
            controls: .init()
        )
    }

    #if DEBUG
    static func debugProposal() -> PlanSpaceProposal {
        let controls = (try? ForgeComposerV14ControlProfile.validated(
            buildDepth: .obsessive,
            autonomy: .fullForge,
            privacy: .localOnly
        )) ?? .init()

        return PlanSpaceProposal(
            intentSummary: "Build a touch-first open-world scooter game that feels excellent on iPhone.",
            questions: [
                PlanQuestion(
                    id: "world-feel",
                    prompt: "How should the riding feel?",
                    reason: "This changes steering, grip, suspension, and camera tuning.",
                    controlKind: .segmentedChoice,
                    options: [
                        PlanOption(
                            id: "realistic",
                            label: "Realistic",
                            detail: "Weighty handling with believable grip and suspension."
                        ),
                        PlanOption(
                            id: "arcade",
                            label: "Arcade",
                            detail: "Fast response, forgiving grip, and easier recovery."
                        ),
                    ]
                ),
                PlanQuestion(
                    id: "camera",
                    prompt: "Which camera should ship?",
                    reason: "Camera choice changes controls, HUD placement, and comfort testing.",
                    controlKind: .segmentedChoice,
                    options: [
                        PlanOption(id: "first", label: "First person", detail: "Rider-eye view."),
                        PlanOption(id: "third", label: "Third person", detail: "Follow camera behind the scooter."),
                        PlanOption(id: "both", label: "Both", detail: "Switchable first- and third-person cameras."),
                    ]
                ),
                PlanQuestion(
                    id: "orientation",
                    prompt: "How should the game use the display?",
                    reason: "This changes the runtime orientation contract and touch layout.",
                    controlKind: .orientation,
                    options: [
                        PlanOption(id: "landscape", label: "Landscape", detail: "Wide driving layout."),
                        PlanOption(id: "auto", label: "Auto", detail: "Adapt when the host can do so safely."),
                    ]
                ),
            ],
            controls: controls
        )
    }

    static var debugAnswers: [String: PlanAnswer] {
        [
            "world-feel": .choice("realistic"),
            "camera": .choice("both"),
            "orientation": .decideForMe,
        ]
    }
    #endif
}

/// Converts a canonical ready summary into a visible, editable composer draft.
/// This is deliberately not execution state. Delegated decisions stay explicit
/// and Local Only stays worded as an execution requirement rather than a claim
/// that a hosted route was already disabled by this presentation layer.
enum ForgePlanSpaceComposerHandoff {
    static func text(for summary: ReadyToForgeSummary) -> String {
        var lines = [summary.intentSummary, "", "NovaForge build intent:"]
        lines.append("- Autonomy: \(summary.controls.autonomy.planDisplayTitle)")
        lines.append("- Build depth: \(summary.controls.buildDepth.planDisplayTitle)")
        lines.append("- Intelligence: \(summary.controls.intelligence.planDisplayTitle)")
        lines.append("- Privacy: \(summary.controls.privacy.planDisplayTitle)")
        lines.append("- Creativity: \(percent(summary.controls.creativity.value)) toward inventive")
        lines.append("- Refactor risk: \(percent(summary.controls.refactorRisk.value)) toward rebuild")

        if summary.controls.privacy.isLocalOnly {
            lines.append("- Execution requirement: keep inference local; no hosted fallback")
        }
        if summary.controls.requiresExternalModelQualification {
            lines.append("- Model requirement: qualify the explicit model before execution")
        }

        if !summary.decisions.isEmpty {
            lines.append("")
            lines.append("Plan decisions:")
            for decision in summary.decisions {
                lines.append("- \(decision.prompt): \(description(for: decision.value))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    private static func description(for value: PlanDecisionValue) -> String {
        switch value {
        case .selected(_, let label):
            return label
        case .scalar(let value):
            return conciseNumber(value)
        case .interval(let lower, let upper):
            return "\(conciseNumber(lower))–\(conciseNumber(upper))"
        case .text(let value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .delegatedToNovaForge:
            return "Decide for me — resolve and receipt before execution"
        }
    }

    private static func conciseNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000_001 {
            return String(Int(rounded))
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

// MARK: - Plan Space surface

struct ForgePlanSpaceView: View {
    @Binding var proposal: PlanSpaceProposal
    @Binding var answers: [String: PlanAnswer]
    let commit: (ReadyToForgeSummary) -> Void
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var questionIndex = 0
    @State private var showingTune = false

    private var presentedQuestions: [PlanQuestion] {
        proposal.presentedQuestions
    }

    private var boundedQuestionIndex: Int {
        guard !presentedQuestions.isEmpty else { return 0 }
        return min(max(questionIndex, 0), presentedQuestions.count - 1)
    }

    private var currentQuestion: PlanQuestion? {
        guard !presentedQuestions.isEmpty else { return nil }
        return presentedQuestions[boundedQuestionIndex]
    }

    private var readySummary: ReadyToForgeSummary? {
        proposal.readySummary(answers: answers)
    }

    private var allowsMotion: Bool {
        !reduceMotion && !AgentPerformance.prefersReducedVisualEffects
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AgentBackground(isWorking: false, isAnimated: allowsMotion)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        hero
                        collaborationRail
                        trustRail
                        questionsSection
                        tuneSection
                        readinessSection
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Plan Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .frame(
                            minWidth: AgentDesign.minimumTouchTarget,
                            minHeight: AgentDesign.minimumTouchTarget
                        )
                        .accessibilityIdentifier("planSpaceCancel")
                }
            }
        }
        .accessibilityIdentifier("forgePlanSpace")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                    .accessibilityHidden(true)
                Text("SHAPE THE BUILD")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .tracking(1.0)
                    .foregroundStyle(AgentPalette.cyan)
            }

            Text(proposal.intentSummary)
                .font(.system(size: 26, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("planSpaceIntentSummary")

            Text("Only choices that materially change the result belong here. Nothing in Plan Space starts execution by itself.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var collaborationRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            planSectionHeading(
                "How NovaForge should build",
                detail: "One collaboration mode and one finish line."
            )

            planControlGroup(
                title: "AUTONOMY",
                value: proposal.controls.autonomy.planDisplayTitle
            ) {
                adaptiveChoices {
                    ForEach(ForgeComposerAutonomyIntent.allCases, id: \.rawValue) { value in
                        planChoice(
                            title: value.planDisplayTitle,
                            detail: value.planDisplayDetail,
                            selected: proposal.controls.autonomy == value,
                            tint: value == .fullForge ? AgentPalette.lilac : AgentPalette.cyan,
                            identifier: "planSpaceAutonomy-\(value.rawValue)"
                        ) {
                            updateControls(autonomy: value)
                        }
                    }
                }
            }

            Divider().overlay(AgentPalette.border.opacity(0.24))

            planControlGroup(
                title: "BUILD DEPTH",
                value: proposal.controls.buildDepth.planDisplayTitle
            ) {
                adaptiveChoices {
                    ForEach(ForgeComposerBuildDepthIntent.allCases, id: \.rawValue) { value in
                        planChoice(
                            title: value.planDisplayTitle,
                            detail: value.planDisplayDetail,
                            selected: proposal.controls.buildDepth == value,
                            tint: value == .obsessive ? AgentPalette.lilac : AgentPalette.cyan,
                            identifier: "planSpaceDepth-\(value.rawValue)"
                        ) {
                            updateControls(buildDepth: value)
                        }
                    }
                }
            }
        }
        .padding(16)
        .modifier(
            PlanSpaceSurface(
                tint: AgentPalette.cyan,
                reduceTransparency: reduceTransparency
            )
        )
        .accessibilityIdentifier("planSpaceCollaborationRail")
    }

    private var trustRail: some View {
        VStack(alignment: .leading, spacing: 13) {
            planSectionHeading(
                "Intelligence & privacy",
                detail: "These are intent. Runtime qualification and policy remain authoritative."
            )

            HStack(alignment: .top, spacing: 12) {
                planTruthReadout(
                    symbol: "brain.head.profile",
                    title: "Intelligence",
                    value: proposal.controls.intelligence.planDisplayTitle,
                    detail: proposal.controls.intelligence.planDisplayDetail,
                    tint: AgentPalette.cyan,
                    identifier: "planSpaceIntelligence"
                )

                planTruthReadout(
                    symbol: proposal.controls.privacy.isLocalOnly ? "lock.shield.fill" : "network",
                    title: "Privacy",
                    value: proposal.controls.privacy.planDisplayTitle,
                    detail: proposal.controls.privacy.planDisplayDetail,
                    tint: proposal.controls.privacy.isLocalOnly ? AgentPalette.green : AgentPalette.cyan,
                    identifier: "planSpacePrivacy"
                )
            }

            Text("Specific model/provider changes stay with the qualified model and policy adapters. Plan Space never fabricates a model reference or cloud permission just to make a control tappable.")
                .font(.caption.weight(.medium))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .accessibilityIdentifier("planSpaceTrustRail")
    }

    @ViewBuilder
    private var questionsSection: some View {
        if !proposal.schemaValidationIssues.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AgentPalette.rose)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("This plan needs repair")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    Text("The canonical proposal is malformed, so NovaForge will not present it as ready to forge.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentPalette.secondaryText)
                }
            }
            .padding(16)
            .modifier(
                PlanSpaceSurface(
                    tint: AgentPalette.rose,
                    reduceTransparency: reduceTransparency
                )
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("planSpaceSchemaError")
        } else if presentedQuestions.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AgentPalette.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No material decisions needed")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    Text("NovaForge can carry your intent forward without inventing a questionnaire. Structured decisions appear only when a planner supplies a real fork.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("planSpaceNoQuestions")
        } else if let question = currentQuestion {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("MATERIAL DECISION")
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .tracking(0.9)
                        .foregroundStyle(AgentPalette.cyan)
                    Spacer(minLength: 8)
                    Text("\(boundedQuestionIndex + 1) of \(presentedQuestions.count)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .accessibilityLabel("Decision \(boundedQuestionIndex + 1) of \(presentedQuestions.count)")
                }

                Text(question.prompt)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AgentPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = question.reason,
                   !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(reason)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                questionControl(question)

                if question.allowsDecideForMe {
                    Button {
                        withAnimation(allowsMotion ? .snappy(duration: 0.24) : nil) {
                            answers[question.id] = .decideForMe
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isDelegated(question) ? "checkmark.circle.fill" : "wand.and.stars")
                            Text("Decide for me")
                                .font(.subheadline.weight(.bold))
                            Spacer(minLength: 8)
                            if isDelegated(question) {
                                Text("Delegated")
                                    .font(.caption.weight(.bold))
                            }
                        }
                        .foregroundStyle(isDelegated(question) ? AgentPalette.green : AgentPalette.cyan)
                        .padding(.horizontal, 12)
                        .frame(minHeight: AgentDesign.minimumTouchTarget)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill((isDelegated(question) ? AgentPalette.green : AgentPalette.cyan).opacity(0.08))
                    )
                    .accessibilityHint("Delegates this decision without inventing a hidden choice")
                    .accessibilityIdentifier("planSpaceDecide-\(question.id)")
                }

                questionNavigation
            }
            .padding(16)
            .modifier(
                PlanSpaceSurface(
                    tint: isAnswered(question) ? AgentPalette.green : AgentPalette.cyan,
                    reduceTransparency: reduceTransparency
                )
            )
            .accessibilityIdentifier("planSpaceQuestion-\(question.id)")
        }
    }

    private var questionNavigation: some View {
        HStack(spacing: 10) {
            Button {
                guard questionIndex > 0 else { return }
                withAnimation(allowsMotion ? .snappy(duration: 0.22) : nil) {
                    questionIndex -= 1
                }
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .font(.caption.weight(.bold))
                    .frame(minHeight: AgentDesign.minimumTouchTarget)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)
            .disabled(boundedQuestionIndex == 0)
            .opacity(boundedQuestionIndex == 0 ? 0.35 : 1)
            .accessibilityIdentifier("planSpacePreviousQuestion")

            Spacer(minLength: 8)

            if boundedQuestionIndex < presentedQuestions.count - 1 {
                Button {
                    withAnimation(allowsMotion ? .snappy(duration: 0.22) : nil) {
                        questionIndex += 1
                    }
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AgentPalette.cyan)
                        .frame(minHeight: AgentDesign.minimumTouchTarget)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("planSpaceNextQuestion")
            }
        }
    }

    @ViewBuilder
    private func questionControl(_ question: PlanQuestion) -> some View {
        switch question.controlKind {
        case .segmentedChoice, .orientation, .imageReference, .visualVariant:
            VStack(spacing: 8) {
                ForEach(question.options) { option in
                    planOptionButton(question: question, option: option)
                }
            }

        case .slider:
            if let range = question.range {
                scalarQuestion(question, range: range)
            }

        case .range:
            if let range = question.range {
                intervalQuestion(question, range: range)
            }

        case .freeText:
            TextField(
                question.placeholder ?? "Type your answer",
                text: Binding(
                    get: { textAnswer(question) ?? "" },
                    set: { answers[question.id] = .text($0) }
                ),
                axis: .vertical
            )
            .font(.body.weight(.medium))
            .foregroundStyle(AgentPalette.ink)
            .lineLimit(2...6)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 52, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AgentPalette.surface.opacity(reduceTransparency ? 1 : 0.52))
            )
            .accessibilityLabel(question.prompt)
            .accessibilityIdentifier("planSpaceText-\(question.id)")
        }
    }

    private func planOptionButton(question: PlanQuestion, option: PlanOption) -> some View {
        let selected = choiceAnswer(question) == option.id
        return Button {
            withAnimation(allowsMotion ? .snappy(duration: 0.22) : nil) {
                answers[question.id] = .choice(option.id)
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(selected ? AgentPalette.cyan : AgentPalette.ink)
                    if let detail = option.detail,
                       !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(detail)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let previewToken = option.previewToken,
                       !previewToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(previewToken)
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(AgentPalette.cyan)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? AgentPalette.cyan : AgentPalette.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        selected
                            ? AgentPalette.cyan.opacity(reduceTransparency ? 0.16 : 0.10)
                            : AgentPalette.surface.opacity(reduceTransparency ? 1 : 0.38)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        selected ? AgentPalette.cyan.opacity(0.46) : AgentPalette.border.opacity(0.20),
                        lineWidth: 0.7
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([option.label, option.detail].compactMap { $0 }.joined(separator: ". "))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("planSpaceOption-\(question.id)-\(option.id)")
    }

    private func scalarQuestion(_ question: PlanQuestion, range: PlanRangeSpec) -> some View {
        let fallback = (range.minimum + range.maximum) / 2
        let step = range.step ?? max((range.maximum - range.minimum) / 100, 0.000_001)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(range.lowLabel ?? conciseNumber(range.minimum))
                Spacer()
                Text(scalarAnswer(question).map(conciseNumber) ?? "Not set")
                    .fontWeight(.bold)
                    .foregroundStyle(scalarAnswer(question) == nil ? AgentPalette.secondaryText : AgentPalette.cyan)
                Spacer()
                Text(range.highLabel ?? conciseNumber(range.maximum))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(AgentPalette.secondaryText)

            Slider(
                value: Binding(
                    get: { scalarAnswer(question) ?? fallback },
                    set: { answers[question.id] = .scalar(snapped($0, range: range)) }
                ),
                in: range.minimum...range.maximum,
                step: step
            )
            .tint(AgentPalette.cyan)
            .accessibilityLabel(question.prompt)
            .accessibilityValue(scalarAnswer(question).map(conciseNumber) ?? "Not set")
            .accessibilityIdentifier("planSpaceSlider-\(question.id)")
        }
    }

    private func intervalQuestion(_ question: PlanQuestion, range: PlanRangeSpec) -> some View {
        let current = intervalAnswer(question)
        let fallbackLower = range.minimum + (range.maximum - range.minimum) * 0.25
        let fallbackUpper = range.minimum + (range.maximum - range.minimum) * 0.75
        let step = range.step ?? max((range.maximum - range.minimum) / 100, 0.000_001)

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Low \(current.map { conciseNumber($0.lower) } ?? "Not set")")
                Spacer()
                Text("High \(current.map { conciseNumber($0.upper) } ?? "Not set")")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(current == nil ? AgentPalette.secondaryText : AgentPalette.cyan)

            Slider(
                value: Binding(
                    get: { current?.lower ?? fallbackLower },
                    set: { newValue in
                        let upper = intervalAnswer(question)?.upper ?? fallbackUpper
                        let lower = min(snapped(newValue, range: range), upper)
                        answers[question.id] = .interval(lower: lower, upper: upper)
                    }
                ),
                in: range.minimum...range.maximum,
                step: step
            )
            .tint(AgentPalette.cyan)
            .accessibilityLabel("\(question.prompt), lower bound")

            Slider(
                value: Binding(
                    get: { intervalAnswer(question)?.upper ?? fallbackUpper },
                    set: { newValue in
                        let lower = intervalAnswer(question)?.lower ?? fallbackLower
                        let upper = max(snapped(newValue, range: range), lower)
                        answers[question.id] = .interval(lower: lower, upper: upper)
                    }
                ),
                in: range.minimum...range.maximum,
                step: step
            )
            .tint(AgentPalette.lilac)
            .accessibilityLabel("\(question.prompt), upper bound")
        }
        .accessibilityIdentifier("planSpaceRange-\(question.id)")
    }

    private var tuneSection: some View {
        DisclosureGroup(isExpanded: $showingTune) {
            VStack(spacing: 16) {
                normalizedIntentSlider(
                    title: "CREATIVITY",
                    low: "Faithful",
                    high: "Inventive",
                    value: proposal.controls.creativity.value,
                    tint: AgentPalette.lilac,
                    identifier: "planSpaceCreativity"
                ) { value in
                    updateControls(creativity: value)
                }

                Divider().overlay(AgentPalette.border.opacity(0.24))

                normalizedIntentSlider(
                    title: "REFACTOR RISK",
                    low: "Preserve",
                    high: "Rebuild",
                    value: proposal.controls.refactorRisk.value,
                    tint: AgentPalette.cyan,
                    identifier: "planSpaceRefactorRisk"
                ) { value in
                    updateControls(refactorRisk: value)
                }
            }
            .padding(.top, 14)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "dial.medium")
                    .foregroundStyle(AgentPalette.cyan)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tune the build")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    Text("Creativity and refactor risk stay out of the way until you ask for them.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentPalette.secondaryText)
                }
            }
        }
        .tint(AgentPalette.cyan)
        .padding(.vertical, 2)
        .accessibilityIdentifier("planSpaceTune")
    }

    @ViewBuilder
    private var readinessSection: some View {
        if let summary = readySummary {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AgentPalette.green)
                        .accessibilityHidden(true)
                    Text("READY FOR HANDOFF")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .tracking(1.0)
                        .foregroundStyle(AgentPalette.green)
                    Spacer(minLength: 8)
                    Text(summary.controls.buildDepth.planDisplayTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AgentPalette.secondaryText)
                }

                HStack(spacing: 8) {
                    compactSummaryToken(summary.controls.autonomy.planDisplayTitle, tint: AgentPalette.cyan)
                    compactSummaryToken(summary.controls.privacy.planDisplayTitle, tint: summary.controls.privacy.isLocalOnly ? AgentPalette.green : AgentPalette.cyan)
                }

                if summary.requiresMissionResolution {
                    Label(
                        "\(summary.delegatedDecisionIDs.count) delegated decision\(summary.delegatedDecisionIDs.count == 1 ? "" : "s") remain unresolved. Mission authority must resolve and receipt them before execution.",
                        systemImage: "wand.and.stars"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentPalette.cyan)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    commit(summary)
                } label: {
                    HStack(spacing: 8) {
                        Text("Return plan to Composer")
                            .font(.headline.weight(.bold))
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.down.right")
                            .font(.system(size: 13, weight: .black))
                    }
                    .foregroundStyle(AgentPalette.ink)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AgentPalette.green.opacity(reduceTransparency ? 0.20 : 0.13))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AgentPalette.green.opacity(0.42), lineWidth: 0.8)
                )
                .accessibilityHint("Places the reviewed plan into the editable composer. This does not start execution.")
                .accessibilityIdentifier("planSpaceReadyToForge")
            }
            .padding(16)
            .modifier(
                PlanSpaceSurface(
                    tint: AgentPalette.green,
                    reduceTransparency: reduceTransparency
                )
            )
            .transition(allowsMotion ? .opacity.combined(with: .scale(scale: 0.985)) : .opacity)
        } else if proposal.schemaValidationIssues.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .accessibilityHidden(true)
                Text(readinessText)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(AgentPalette.secondaryText)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .accessibilityIdentifier("planSpaceReadiness")
        }
    }

    private var readinessText: String {
        let unresolved = proposal.unresolvedQuestionIDs(answers: answers).count
        guard unresolved > 0 else { return "Reviewing plan" }
        return "\(unresolved) material decision\(unresolved == 1 ? "" : "s") left"
    }

    private func planSectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(AgentPalette.ink)
            Text(detail)
                .font(.caption.weight(.medium))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planControlGroup<Content: View>(
        title: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .tracking(0.8)
                    .foregroundStyle(AgentPalette.secondaryText)
                Spacer(minLength: 8)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AgentPalette.cyan)
            }
            content()
        }
    }

    @ViewBuilder
    private func adaptiveChoices<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8, content: content)
        } else {
            HStack(spacing: 8, content: content)
        }
    }

    private func planChoice(
        title: String,
        detail: String,
        selected: Bool,
        tint: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .black))
                            .accessibilityHidden(true)
                    }
                }
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(selected ? tint : AgentPalette.ink)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 58 : AgentDesign.minimumTouchTarget, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        selected
                            ? tint.opacity(reduceTransparency ? 0.17 : 0.10)
                            : AgentPalette.surface.opacity(reduceTransparency ? 1 : 0.34)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.46) : AgentPalette.border.opacity(0.18), lineWidth: 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier(identifier)
    }

    private func planTruthReadout(
        symbol: String,
        title: String,
        value: String,
        detail: String,
        tint: Color,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(AgentPalette.secondaryText)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AgentPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AgentPalette.surface.opacity(reduceTransparency ? 1 : 0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.65)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value). \(detail)")
        .accessibilityIdentifier(identifier)
    }

    private func normalizedIntentSlider(
        title: String,
        low: String,
        high: String,
        value: Double,
        tint: Color,
        identifier: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .tracking(0.8)
                    .foregroundStyle(AgentPalette.secondaryText)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(tint)
            }

            Slider(
                value: Binding(get: { value }, set: onChange),
                in: 0...1,
                step: 0.05
            )
            .tint(tint)
            .accessibilityLabel(title.capitalized)
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
            .accessibilityIdentifier(identifier)

            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AgentPalette.secondaryText)
        }
    }

    private func compactSummaryToken(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(tint.opacity(0.08), in: Capsule(style: .continuous))
    }

    private func updateControls(
        buildDepth: ForgeComposerBuildDepthIntent? = nil,
        autonomy: ForgeComposerAutonomyIntent? = nil,
        creativity: Double? = nil,
        refactorRisk: Double? = nil
    ) {
        let current = proposal.controls
        let creativityValue = creativity.flatMap { try? ForgeComposerUnitInterval($0) } ?? current.creativity
        let refactorRiskValue = refactorRisk.flatMap { try? ForgeComposerUnitInterval($0) } ?? current.refactorRisk

        guard let updated = try? ForgeComposerV14ControlProfile.validated(
            intelligence: current.intelligence,
            buildDepth: buildDepth ?? current.buildDepth,
            creativity: creativityValue,
            refactorRisk: refactorRiskValue,
            autonomy: autonomy ?? current.autonomy,
            privacy: current.privacy
        ) else {
            return
        }

        withAnimation(allowsMotion ? .snappy(duration: 0.22) : nil) {
            proposal.controls = updated
        }
    }

    private func choiceAnswer(_ question: PlanQuestion) -> String? {
        guard case .choice(let id) = answers[question.id] else { return nil }
        return id
    }

    private func scalarAnswer(_ question: PlanQuestion) -> Double? {
        guard case .scalar(let value) = answers[question.id] else { return nil }
        return value
    }

    private func intervalAnswer(_ question: PlanQuestion) -> (lower: Double, upper: Double)? {
        guard case .interval(let lower, let upper) = answers[question.id] else { return nil }
        return (lower, upper)
    }

    private func textAnswer(_ question: PlanQuestion) -> String? {
        guard case .text(let value) = answers[question.id] else { return nil }
        return value
    }

    private func isDelegated(_ question: PlanQuestion) -> Bool {
        guard case .decideForMe = answers[question.id] else { return false }
        return true
    }

    private func isAnswered(_ question: PlanQuestion) -> Bool {
        guard let answer = answers[question.id] else { return false }
        return question.accepts(answer)
    }

    private func snapped(_ value: Double, range: PlanRangeSpec) -> Double {
        guard let step = range.step else {
            return min(max(value, range.minimum), range.maximum)
        }
        let steps = ((value - range.minimum) / step).rounded()
        return min(max(range.minimum + steps * step, range.minimum), range.maximum)
    }

    private func conciseNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000_001 {
            return String(Int(rounded))
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

// MARK: - Composer entry point

struct ComposerPlanSpaceButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .black))
                    .accessibilityHidden(true)
                Text("Plan")
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
            }
            .foregroundStyle(isEnabled ? AgentPalette.cyan : AgentPalette.secondaryText)
            .padding(.horizontal, 9)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .contentShape(Capsule(style: .continuous))
            .agentControlSurface(
                radius: AgentDesign.minimumTouchTarget / 2,
                tint: AgentPalette.cyan.opacity(isEnabled ? 0.10 : 0.03),
                selected: false
            )
        }
        .buttonStyle(ComposerMenuButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(isEnabled ? "Open Plan Space" : "Plan Space needs a project description")
        .accessibilityHint(isEnabled ? "Uses the current unsent composer draft" : "Describe what you want to make first")
        .accessibilityIdentifier("composerPlanSpaceButton")
    }
}

private struct PlanSpaceSurface: ViewModifier {
    let tint: Color
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency || AgentPerformance.prefersReducedVisualEffects {
            content
                .background(shape.fill(AgentPalette.surfaceElevated))
                .overlay(shape.strokeBorder(tint.opacity(0.24), lineWidth: 0.8))
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(shape.fill(AgentPalette.surfaceElevated.opacity(0.26)))
                .overlay(shape.strokeBorder(tint.opacity(0.18), lineWidth: 0.65))
        }
    }
}

private extension ForgeComposerAutonomyIntent {
    var planDisplayTitle: String {
        switch self {
        case .guideMe: "Guide me"
        case .collaborate: "Collaborate"
        case .fullForge: "Full Forge"
        }
    }

    var planDisplayDetail: String {
        switch self {
        case .guideMe: "Keep material choices with me"
        case .collaborate: "Share decisions as we build"
        case .fullForge: "Autonomous loop within policy"
        }
    }
}

private extension ForgeComposerBuildDepthIntent {
    var planDisplayTitle: String {
        switch self {
        case .quick: "Quick"
        case .complete: "Complete"
        case .obsessive: "Obsessive"
        }
    }

    var planDisplayDetail: String {
        switch self {
        case .quick: "Fast useful result"
        case .complete: "Build, run, test, polish"
        case .obsessive: "Repeat until acceptance or blocker"
        }
    }
}

private extension ForgeComposerIntelligenceIntent {
    var planDisplayTitle: String {
        switch self {
        case .automatic: "Auto"
        case .explicitModel: "Specific model"
        }
    }

    var planDisplayDetail: String {
        switch self {
        case .automatic:
            "Choose from qualified routes at execution"
        case .explicitModel:
            "Requires external compatibility qualification"
        }
    }
}

private extension ForgeComposerPrivacyIntent {
    var planDisplayTitle: String {
        switch self {
        case .localOnly:
            "Local Only"
        case .providerAllowlist(let providerIDs):
            "\(providerIDs.count) provider\(providerIDs.count == 1 ? "" : "s") allowed"
        }
    }

    var planDisplayDetail: String {
        switch self {
        case .localOnly:
            "No silent hosted fallback"
        case .providerAllowlist:
            "Only the canonical allowlist may be used"
        }
    }
}
