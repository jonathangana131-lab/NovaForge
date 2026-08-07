//
//  ChatHeaderStrip.swift
//  NovaForge
//
//  V13 repurposes this registered tombstone for Plan Space so the first
//  product slice can land without project-file churn. The retired chip-train
//  header is not returning; ForgeHeader remains the only primary chat header.
//

import SwiftUI
import UIKit

// MARK: - Plan Space

/// Plan Space is intentionally pre-run. It helps a person express the few
/// decisions that materially change the build, then returns a visible,
/// editable handoff to the ordinary Forge composer. It never silently starts
/// work, grants authority, or claims that a provider supports a hidden knob.
struct ForgePlanSpaceView: View {
    @Binding var draft: ForgePlanSpaceDraft
    let commit: (String) -> Void
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var intentFocused: Bool

    private var allowsMotion: Bool {
        NovaMotion.enabled(reduceMotion: reduceMotion)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AgentBackground(isWorking: false, isAnimated: allowsMotion)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        intro
                        intentQuestion
                        buildDepthQuestion
                        creativityQuestion
                        decisionFooter
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
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
        .onAppear {
            if draft.trimmedIntent.isEmpty {
                intentFocused = true
            }
        }
        .accessibilityIdentifier("forgePlanSpace")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Shape the build before NovaForge starts.")
                .font(.system(size: 27, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Only decisions that change the result belong here. You can edit the final request in Forge before sending it.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var intentQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            questionHeader(
                index: 1,
                title: "What do you want to make?",
                detail: "Describe the outcome, not implementation jargon."
            )

            TextField(
                "A driving game, a study app, a dashboard…",
                text: $draft.intent,
                axis: .vertical
            )
            .font(.body.weight(.medium))
            .foregroundStyle(AgentPalette.ink)
            .lineLimit(3...8)
            .focused($intentFocused)
            .submitLabel(.done)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(minHeight: 58, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AgentPalette.surface.opacity(reduceTransparency ? 1 : 0.56))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        draft.trimmedIntent.isEmpty
                            ? AgentPalette.border.opacity(0.30)
                            : AgentPalette.cyan.opacity(0.42),
                        lineWidth: 0.8
                    )
            )
            .accessibilityLabel("Project intent")
            .accessibilityHint("Describe what NovaForge should make")
            .accessibilityIdentifier("planSpaceIntent")
        }
        .padding(14)
        .modifier(
            ForgePlanQuestionSurface(
                tint: AgentPalette.cyan,
                reduceTransparency: reduceTransparency
            )
        )
    }

    private var buildDepthQuestion: some View {
        VStack(alignment: .leading, spacing: 11) {
            questionHeader(
                index: 2,
                title: "How far should the build go?",
                detail: "Choose how much building, testing, and polish NovaForge should do."
            )

            choiceLayout {
                ForEach(ForgeBuildDepth.allCases) { depth in
                    planChoiceButton(
                        title: depth.title,
                        symbol: depth.symbol,
                        detail: depth.impact,
                        selected: draft.buildDepth == depth,
                        tint: depth == .obsessive ? AgentPalette.lilac : AgentPalette.cyan,
                        identifier: "planSpaceDepth-\(depth.rawValue)"
                    ) {
                        selectBuildDepth(depth)
                    }
                }
            }

            if let depth = draft.buildDepth {
                impactPreview(
                    label: "BUILD LOOP",
                    text: depth.impact,
                    tint: depth == .obsessive ? AgentPalette.lilac : AgentPalette.cyan
                )
            }
        }
        .padding(14)
        .modifier(
            ForgePlanQuestionSurface(
                tint: draft.buildDepth == .obsessive ? AgentPalette.lilac : AgentPalette.cyan,
                reduceTransparency: reduceTransparency
            )
        )
    }

    private var creativityQuestion: some View {
        VStack(alignment: .leading, spacing: 11) {
            questionHeader(
                index: 3,
                title: "How inventive can NovaForge be?",
                detail: "The goal stays protected; this controls how freely the product approach may evolve."
            )

            choiceLayout {
                ForEach(ForgeCreativity.allCases) { creativity in
                    planChoiceButton(
                        title: creativity.title,
                        symbol: creativity.symbol,
                        detail: creativity.impact,
                        selected: draft.creativity == creativity,
                        tint: creativity == .inventive ? AgentPalette.lilac : AgentPalette.primaryAccent,
                        identifier: "planSpaceCreativity-\(creativity.rawValue)"
                    ) {
                        selectCreativity(creativity)
                    }
                }
            }

            if let creativity = draft.creativity {
                impactPreview(
                    label: "DESIGN FREEDOM",
                    text: creativity.impact,
                    tint: creativity == .inventive ? AgentPalette.lilac : AgentPalette.primaryAccent
                )
            }
        }
        .padding(14)
        .modifier(
            ForgePlanQuestionSurface(
                tint: draft.creativity == .inventive ? AgentPalette.lilac : AgentPalette.primaryAccent,
                reduceTransparency: reduceTransparency
            )
        )
    }

    @ViewBuilder
    private var decisionFooter: some View {
        VStack(spacing: 10) {
            if draft.isReady {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(AgentPalette.green)
                        Text("READY TO FORGE")
                            .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .tracking(1.0)
                            .foregroundStyle(AgentPalette.green)
                        Spacer(minLength: 8)
                        Text(draft.compactSummary)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }

                    Text(draft.trimmedIntent)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(3)

                    Button {
                        guard let handoff = draft.composerHandoff else { return }
                        intentFocused = false
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        commit(handoff)
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
                    .accessibilityHint("Places this plan in the Forge composer so you can review it before sending")
                    .accessibilityIdentifier("planSpaceReadyToForge")
                }
                .padding(14)
                .modifier(
                    ForgePlanQuestionSurface(
                        tint: AgentPalette.green,
                        reduceTransparency: reduceTransparency
                    )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(AgentPalette.secondaryText)
                    Text("\(draft.answeredDecisionCount)/2 build decisions answered")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AgentPalette.secondaryText)
                    Spacer()
                }
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .accessibilityLabel("\(draft.answeredDecisionCount) of 2 build decisions answered")

                Button {
                    applyRecommendedPlan()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "wand.and.stars")
                        Text("Decide for me")
                            .fontWeight(.bold)
                    }
                    .foregroundStyle(AgentPalette.cyan)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: AgentDesign.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Chooses the balanced Polished and Faithful defaults")
                .accessibilityIdentifier("planSpaceDecideForMe")
            }
        }
        .animation(allowsMotion ? .snappy(duration: 0.32) : nil, value: draft.isReady)
    }

    private func questionHeader(index: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.monospacedDigit().weight(.black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 28, height: 28)
                .background(AgentPalette.cyan.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

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
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func choiceLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8, content: content)
        } else {
            HStack(spacing: 8, content: content)
        }
    }

    private func planChoiceButton(
        title: String,
        symbol: String,
        detail: String,
        selected: Bool,
        tint: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .black))
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
            }
            .foregroundStyle(selected ? tint : AgentPalette.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        selected
                            ? tint.opacity(reduceTransparency ? 0.22 : 0.14)
                            : AgentPalette.surface.opacity(reduceTransparency ? 1 : 0.34)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        selected ? tint.opacity(0.58) : AgentPalette.border.opacity(0.22),
                        lineWidth: selected ? 1.0 : 0.6
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier(identifier)
    }

    private func impactPreview(label: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(tint.opacity(0.82))
                .frame(width: 2.5)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .tracking(0.8)
                    .foregroundStyle(tint)
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func selectBuildDepth(_ depth: ForgeBuildDepth) {
        withAnimation(allowsMotion ? .snappy(duration: 0.28) : nil) {
            draft.buildDepth = depth
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func selectCreativity(_ creativity: ForgeCreativity) {
        withAnimation(allowsMotion ? .snappy(duration: 0.28) : nil) {
            draft.creativity = creativity
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func applyRecommendedPlan() {
        withAnimation(allowsMotion ? .snappy(duration: 0.32) : nil) {
            draft.decideForMe()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

private struct ForgePlanQuestionSurface: ViewModifier {
    let tint: Color
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency {
            content
                .background(shape.fill(AgentPalette.surfaceElevated))
                .overlay(shape.strokeBorder(tint.opacity(0.24), lineWidth: 0.8))
        } else {
            content
                .background(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                AgentPalette.surfaceElevated.opacity(0.46),
                                tint.opacity(0.055),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .agentGlass(radius: 22, tint: tint.opacity(0.08))
                .overlay(shape.strokeBorder(tint.opacity(0.18), lineWidth: 0.65))
        }
    }
}
