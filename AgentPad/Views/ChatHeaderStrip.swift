//
//  ChatHeaderStrip.swift
//  NovaForge
//
//  The retired double-deck chat header stays retired. V13 reuses this already
//  registered source slot for the Plan Space presentation layer so the app can
//  render the canonical ForgePlanCore contracts without creating a second
//  planning authority.
//

import Foundation
import ForgePlanCore
import SwiftUI
import UIKit

// MARK: - Plan Space presentation adapter

/// Presentation-only helpers around the canonical ForgePlanCore domain.
/// The normal composer path intentionally invents no material questions: until
/// a planner/mission adapter supplies real ones, Plan Space exposes truthful
/// build controls and can hand the user's current intent back to the composer.
enum ForgePlanSpacePresentation {
    static let debugLaunchArgument = "--forge-plan-space-demo"

    static func proposal(intent: String) -> PlanSpaceProposal {
        PlanSpaceProposal(
            intentSummary: intent.trimmingCharacters(in: .whitespacesAndNewlines),
            questions: []
        )
    }

    #if DEBUG
    static func debugProposal() -> PlanSpaceProposal {
        PlanSpaceProposal(
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
                        PlanOption(id: "first", label: "First", detail: "Rider-eye view."),
                        PlanOption(id: "third", label: "Third", detail: "Follow camera behind the scooter."),
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
            controls: ForgeControlProfile(
                intelligence: .deep,
                buildDepth: .polished,
                creativity: .init(0.72),
                refactorRisk: .init(0.35),
                autonomy: .assist,
                localCompute: .init(0.45),
                cloudResource: .init(0.55)
            )
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
/// This is deliberately a presentation handoff, not durable Mission Engine
/// state. Delegated decisions remain explicit instead of being fabricated.
enum ForgePlanSpaceComposerHandoff {
    static func text(for summary: ReadyToForgeSummary) -> String {
        var lines = [summary.intentSummary, "", "NovaForge build preferences:"]
        lines.append("- Intelligence: \(summary.controls.intelligence.planDisplayTitle)")
        lines.append("- Build depth: \(summary.controls.buildDepth.planDisplayTitle)")
        lines.append("- Creativity: \(percent(summary.controls.creativity.value)) toward inventive")
        lines.append("- Refactor risk: \(percent(summary.controls.refactorRisk.value)) toward rebuild")
        lines.append("- Autonomy intent: \(summary.controls.autonomy.planDisplayTitle) (policy still applies)")
        lines.append("- Local compute: \(percent(summary.controls.localCompute.value)) toward maximum")
        lines.append("- Cloud resource: \(percent(summary.controls.cloudResource.value)) toward maximum")

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
            return "Decide for me — resolve before execution"
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
    @State private var showingAdvancedControls = false

    private var allowsMotion: Bool {
        NovaMotion.enabled(reduceMotion: reduceMotion) &&
            !AgentPerformance.prefersReducedVisualEffects
    }

    private var readySummary: ReadyToForgeSummary? {
        proposal.readySummary(answers: answers)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AgentBackground(isWorking: false, isAnimated: allowsMotion)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        intro
                        intentCard
                        buildControlsCard
                        questionsSection
                        advancedControlsCard
                        readinessCard
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 34)
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

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shape the build before it starts.")
                .font(.system(size: 27, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("NovaForge asks only decisions that materially change the result. Everything here remains reviewable before Send.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var intentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            planEyebrow("INTENT", tint: AgentPalette.cyan)
            Text(proposal.intentSummary)
                .font(.headline.weight(.bold))
                .foregroundStyle(AgentPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .modifier(
            ForgePlanQuestionSurface(
                tint: AgentPalette.cyan,
                reduceTransparency: reduceTransparency
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("planSpaceIntentSummary")
    }

    private var buildControlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Build controls")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    Text("Product strategy, not hidden provider parameter soup.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentPalette.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(AgentPalette.lilac)
                    .accessibilityHidden(true)
            }

            labeledControl("FORGE INTELLIGENCE", detail: proposal.controls.intelligence.planDisplayTitle) {
                choiceGrid {
                    ForEach(ForgeIntelligence.allCases, id: \.rawValue) { value in
                        compactChoice(
                            title: value.planDisplayTitle,
                            selected: proposal.controls.intelligence == value,
                            tint: AgentPalette.cyan,
                            identifier: "planSpaceIntelligence-\(value.rawValue)"
                        ) {
                            proposal.controls.intelligence = value
                            selectionHaptic()
                        }
                    }
                }
            }

            labeledControl("BUILD DEPTH", detail: proposal.controls.buildDepth.planDisplayTitle) {
                choiceGrid {
                    ForEach(ForgeBuildDepth.allCases, id: \.rawValue) { value in
                        compactChoice(
                            title: value.planDisplayTitle,
                            selected: proposal.controls.buildDepth == value,
                            tint: value == .obsessive ? AgentPalette.lilac : AgentPalette.cyan,
                            identifier: "planSpaceDepth-\(value.rawValue)"
                        ) {
                            proposal.controls.buildDepth = value
                            selectionHaptic()
                        }
                    }
                }
            }

            normalizedSlider(
                title: "CREATIVITY",
                low: "Faithful",
                high: "Inventive",
                value: Binding(
                    get: { proposal.controls.creativity.value },
                    set: { proposal.controls.creativity = .init($0) }
                ),
                tint: AgentPalette.lilac,
                identifier: "planSpaceCreativity"
            )
        }
        .padding(15)
        .modifier(
            ForgePlanQuestionSurface(
                tint: AgentPalette.lilac,
                reduceTransparency: reduceTransparency
            )
        )
    }

    @ViewBuilder
    private var questionsSection: some View {
        if !proposal.schemaValidationIssues.isEmpty {
            Label(
                "This plan is malformed, so NovaForge will not forge it.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AgentPalette.rose)
            .padding(15)
            .modifier(
                ForgePlanQuestionSurface(
                    tint: AgentPalette.rose,
                    reduceTransparency: reduceTransparency
                )
            )
            .accessibilityIdentifier("planSpaceSchemaError")
        } else if proposal.presentedQuestions.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AgentPalette.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No material questions yet")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    Text("NovaForge can use the intent and build controls without inventing extra decisions. A planner can supply structured questions here when one is genuinely needed.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(15)
            .modifier(
                ForgePlanQuestionSurface(
                    tint: AgentPalette.green,
                    reduceTransparency: reduceTransparency
                )
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("planSpaceNoQuestions")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Material decisions")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AgentPalette.ink)
                ForEach(Array(proposal.presentedQuestions.enumerated()), id: \.element.id) { index, question in
                    questionCard(question, index: index + 1)
                }
            }
        }
    }

    private func questionCard(_ question: PlanQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index)")
                    .font(.caption.monospacedDigit().weight(.black))
                    .foregroundStyle(AgentPalette.cyan)
                    .frame(width: 28, height: 28)
                    .background(AgentPalette.cyan.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(question.prompt)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    if let reason = question.reason,
                       !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(reason)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            questionControl(question)

            if question.allowsDecideForMe {
                Button {
                    withAnimation(allowsMotion ? .snappy(duration: 0.24) : nil) {
                        answers[question.id] = .decideForMe
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isDelegated(question) ? "checkmark.circle.fill" : "wand.and.stars")
                        Text("Decide for me")
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        if isDelegated(question) {
                            Text("Delegated")
                                .font(.caption2.weight(.bold))
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
        }
        .padding(15)
        .modifier(
            ForgePlanQuestionSurface(
                tint: isAnswered(question) ? AgentPalette.green : AgentPalette.cyan,
                reduceTransparency: reduceTransparency
            )
        )
        .accessibilityIdentifier("planSpaceQuestion-\(question.id)")
    }

    @ViewBuilder
    private func questionControl(_ question: PlanQuestion) -> some View {
        switch question.controlKind {
        case .segmentedChoice, .orientation, .imageReference, .visualVariant:
            choiceGrid {
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
                    .fill(AgentPalette.surface.opacity(reduceTransparency ? 1 : 0.42))
            )
            .accessibilityLabel(question.prompt)
            .accessibilityIdentifier("planSpaceText-\(question.id)")
        }
    }

    private func planOptionButton(question: PlanQuestion, option: PlanOption) -> some View {
        let selected = choiceAnswer(question) == option.id
        return Button {
            withAnimation(allowsMotion ? .snappy(duration: 0.24) : nil) {
                answers[question.id] = .choice(option.id)
            }
            selectionHaptic()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(option.label)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    Spacer(minLength: 2)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                if let detail = option.detail,
                   !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(detail)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                }
                if let previewToken = option.previewToken,
                   !previewToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(previewToken)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(AgentPalette.cyan)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? AgentPalette.cyan : AgentPalette.ink)
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        selected
                            ? AgentPalette.cyan.opacity(reduceTransparency ? 0.18 : 0.12)
                            : AgentPalette.surface.opacity(reduceTransparency ? 1 : 0.34)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        selected ? AgentPalette.cyan.opacity(0.52) : AgentPalette.border.opacity(0.22),
                        lineWidth: selected ? 0.9 : 0.6
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
        VStack(alignment: .leading, spacing: 8) {
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
                    get: { scalarAnswer(question) ?? ((range.minimum + range.maximum) / 2) },
                    set: { answers[question.id] = .scalar(snapped($0, range: range)) }
                ),
                in: range.minimum...range.maximum,
                step: range.step ?? max((range.maximum - range.minimum) / 100, 0.000_001)
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
                        let upper = current?.upper ?? fallbackUpper
                        let lower = min(snapped(newValue, range: range), upper)
                        answers[question.id] = .interval(lower: lower, upper: upper)
                    }
                ),
                in: range.minimum...range.maximum,
                step: range.step ?? max((range.maximum - range.minimum) / 100, 0.000_001)
            )
            .tint(AgentPalette.cyan)
            .accessibilityLabel("\(question.prompt), lower bound")

            Slider(
                value: Binding(
                    get: { current?.upper ?? fallbackUpper },
                    set: { newValue in
                        let lower = current?.lower ?? fallbackLower
                        let upper = max(snapped(newValue, range: range), lower)
                        answers[question.id] = .interval(lower: lower, upper: upper)
                    }
                ),
                in: range.minimum...range.maximum,
                step: range.step ?? max((range.maximum - range.minimum) / 100, 0.000_001)
            )
            .tint(AgentPalette.lilac)
            .accessibilityLabel("\(question.prompt), upper bound")
        }
        .accessibilityIdentifier("planSpaceRange-\(question.id)")
    }

    private var advancedControlsCard: some View {
        DisclosureGroup(isExpanded: $showingAdvancedControls) {
            VStack(spacing: 15) {
                normalizedSlider(
                    title: "REFACTOR RISK",
                    low: "Preserve",
                    high: "Rebuild",
                    value: Binding(
                        get: { proposal.controls.refactorRisk.value },
                        set: { proposal.controls.refactorRisk = .init($0) }
                    ),
                    tint: AgentPalette.lilac,
                    identifier: "planSpaceRefactorRisk"
                )

                labeledControl("AUTONOMY", detail: proposal.controls.autonomy.planDisplayTitle) {
                    choiceGrid {
                        ForEach(ForgeAutonomy.allCases, id: \.rawValue) { value in
                            compactChoice(
                                title: value.planDisplayTitle,
                                selected: proposal.controls.autonomy == value,
                                tint: AgentPalette.cyan,
                                identifier: "planSpaceAutonomy-\(value.rawValue)"
                            ) {
                                proposal.controls.autonomy = value
                                selectionHaptic()
                            }
                        }
                    }
                }

                Text("Autonomy is an intent envelope. It never bypasses NovaForge approval or execution policy.")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                normalizedSlider(
                    title: "LOCAL COMPUTE",
                    low: "Cool & efficient",
                    high: "Maximum",
                    value: Binding(
                        get: { proposal.controls.localCompute.value },
                        set: { proposal.controls.localCompute = .init($0) }
                    ),
                    tint: AgentPalette.green,
                    identifier: "planSpaceLocalCompute"
                )

                normalizedSlider(
                    title: "CLOUD RESOURCE",
                    low: "Efficient",
                    high: "Maximum",
                    value: Binding(
                        get: { proposal.controls.cloudResource.value },
                        set: { proposal.controls.cloudResource = .init($0) }
                    ),
                    tint: AgentPalette.cyan,
                    identifier: "planSpaceCloudResource"
                )
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "dial.medium")
                    .foregroundStyle(AgentPalette.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced build controls")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    Text("Refactor risk, autonomy, and compute budgets")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AgentPalette.secondaryText)
                }
            }
        }
        .tint(AgentPalette.cyan)
        .padding(15)
        .modifier(
            ForgePlanQuestionSurface(
                tint: AgentPalette.cyan,
                reduceTransparency: reduceTransparency
            )
        )
        .accessibilityIdentifier("planSpaceAdvancedControls")
    }

    @ViewBuilder
    private var readinessCard: some View {
        if let summary = readySummary {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AgentPalette.green)
                    Text("READY TO FORGE")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .tracking(1.0)
                        .foregroundStyle(AgentPalette.green)
                    Spacer(minLength: 8)
                    Text(proposal.controls.buildDepth.planDisplayTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AgentPalette.secondaryText)
                }

                Text(summary.intentSummary)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(4)

                if summary.requiresMissionResolution {
                    Label(
                        "\(summary.delegatedDecisionIDs.count) delegated decision\(summary.delegatedDecisionIDs.count == 1 ? "" : "s") remain explicitly unresolved for the Mission Engine.",
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
                        Text("Use this plan")
                            .font(.headline.weight(.bold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .black))
                    }
                    .foregroundStyle(AgentPalette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AgentPalette.green.opacity(reduceTransparency ? 0.24 : 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AgentPalette.green.opacity(0.46), lineWidth: 0.9)
                )
                .accessibilityHint("Places this plan in the Forge composer for review; it does not start execution")
                .accessibilityIdentifier("planSpaceReadyToForge")
            }
            .padding(15)
            .modifier(
                ForgePlanQuestionSurface(
                    tint: AgentPalette.green,
                    reduceTransparency: reduceTransparency
                )
            )
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        } else if proposal.schemaValidationIssues.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
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

    private func labeledControl<Content: View>(
        _ title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                planEyebrow(title, tint: AgentPalette.secondaryText)
                Spacer()
                Text(detail)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AgentPalette.cyan)
            }
            content()
        }
    }

    private func normalizedSlider(
        title: String,
        low: String,
        high: String,
        value: Binding<Double>,
        tint: Color,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                planEyebrow(title, tint: AgentPalette.secondaryText)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(tint)
            }
            Slider(value: value, in: 0...1, step: 0.05)
                .tint(tint)
                .accessibilityLabel(title.capitalized)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
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

    private func planEyebrow(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
            .tracking(0.8)
            .foregroundStyle(tint)
    }

    @ViewBuilder
    private func choiceGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8, content: content)
        } else {
            HStack(spacing: 8, content: content)
        }
    }

    private func compactChoice(
        title: String,
        selected: Bool,
        tint: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                }
            }
            .foregroundStyle(selected ? tint : AgentPalette.ink)
            .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        selected
                            ? tint.opacity(reduceTransparency ? 0.18 : 0.11)
                            : AgentPalette.surface.opacity(reduceTransparency ? 1 : 0.30)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.48) : AgentPalette.border.opacity(0.20), lineWidth: 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier(identifier)
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

    private func selectionHaptic() {
        UISelectionFeedbackGenerator().selectionChanged()
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

private struct ForgePlanQuestionSurface: ViewModifier {
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
                .background(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                AgentPalette.surfaceElevated.opacity(0.48),
                                tint.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .agentGlass(radius: 22, tint: tint.opacity(0.07))
                .overlay(shape.strokeBorder(tint.opacity(0.18), lineWidth: 0.65))
        }
    }
}

private extension ForgeIntelligence {
    var planDisplayTitle: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .deep: "Deep"
        case .extreme: "Extreme"
        }
    }
}

private extension ForgeBuildDepth {
    var planDisplayTitle: String {
        switch self {
        case .prototype: "Prototype"
        case .polished: "Polished"
        case .obsessive: "Go Crazy"
        }
    }
}

private extension ForgeAutonomy {
    var planDisplayTitle: String {
        switch self {
        case .ask: "Ask"
        case .assist: "Assist"
        case .build: "Build"
        case .autopilot: "Autopilot"
        }
    }
}
