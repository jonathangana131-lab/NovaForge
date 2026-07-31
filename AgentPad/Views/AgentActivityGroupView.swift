import SwiftUI

/// One compact transcript row for a canonical agent run.
///
/// The view only receives classified projection values. Journal events, tool
/// arguments, provider frames, and raw output never enter this presentation
/// boundary. Every outgoing action preserves the exact canonical command.
struct AgentActivityGroupView: View {
    let group: AgentActivityGroup
    let onCommand: (AgentActivityCommand) -> Void
    let onReviewApproval: (AgentActivityApproval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false
    @Namespace private var glassNamespace

    private var presentation: AgentCanonicalActivityPresentation {
        AgentCanonicalActivityPresentation(group: group, isExpanded: isExpanded)
    }

    private var canExpand: Bool {
        !group.items.isEmpty || !group.attempts.isEmpty || group.errorMessage != nil
    }

    private var allowsMotion: Bool {
        NovaMotion.enabled(reduceMotion: reduceMotion)
    }

    var body: some View {
        let summaryLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 6))

        VStack(alignment: .leading, spacing: 6) {
            summaryLayout {
                AgentActivitySummaryRow(
                    group: group,
                    presentation: presentation,
                    isExpanded: isExpanded,
                    canExpand: canExpand,
                    allowsMotion: allowsMotion,
                    toggleExpanded: toggleExpanded
                )

                AgentActivityCommandCluster(
                    group: group,
                    glassNamespace: glassNamespace,
                    allowsMotion: allowsMotion,
                    send: send
                )
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    alignment: .trailing
                )
            }

            if let approval = group.pendingApproval {
                AgentActivityApprovalReviewView(
                    approval: approval,
                    action: AgentCanonicalActivityPresentation.approvalAction(
                        in: group,
                        approval: approval
                    ),
                    review: { review(approval) }
                )
                .transition(.opacity)
            }

            if isExpanded {
                AgentActivityDisclosureLane(
                    group: group,
                    presentation: presentation,
                    openReceipt: openReceipt
                )
                .transition(.opacity)
            }

            if !presentation.visibleArtifacts.isEmpty {
                AgentArtifactHandoffList(
                    artifacts: presentation.visibleArtifacts,
                    hiddenArtifactCount: presentation.hiddenArtifactCount,
                    openArtifact: openArtifact,
                    openFullDetail: openReceipt
                )
            }
        }
        .animation(allowsMotion ? .smooth(duration: 0.16) : nil, value: isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentActivityGroup")
    }

    private func toggleExpanded() {
        guard canExpand else { return }
        NovaHaptics.tick()
        isExpanded.toggle()
    }

    private func send(_ command: AgentActivityCommand) {
        guard group.accepts(command) else { return }
        NovaHaptics.tick()
        onCommand(command)
    }

    private func review(_ approval: AgentActivityApproval) {
        guard group.pendingApproval?.id == approval.id,
              group.pendingApproval?.callID == approval.callID
        else { return }
        NovaHaptics.surfaceRevealed()
        onReviewApproval(approval)
    }

    private func openReceipt() {
        send(group.openReceiptCommand)
    }

    private func openArtifact(_ artifact: AgentActivityArtifact) {
        send(artifact.openCommand)
    }
}

private struct AgentActivitySummaryRow: View {
    let group: AgentActivityGroup
    let presentation: AgentCanonicalActivityPresentation
    let isExpanded: Bool
    let canExpand: Bool
    let allowsMotion: Bool
    let toggleExpanded: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let contentLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 7))

        Button(action: toggleExpanded) {
            HStack(
                alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
                spacing: 7
            ) {
                AgentActivityStateGlyph(
                    state: group.state,
                    size: 18,
                    symbol: presentation.primarySymbol
                )
                    .padding(.top, dynamicTypeSize.isAccessibilitySize ? 3 : 0)
                    .accessibilityHidden(true)

                contentLayout {
                    AgentActivityLiveSummaryText(
                        text: presentation.primarySummary,
                        isLive: !group.state.isTerminal,
                        allowsMotion: allowsMotion
                    )
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(
                            horizontal: false,
                            vertical: dynamicTypeSize.isAccessibilitySize
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(2)

                    HStack(spacing: 7) {
                        if group.state != .succeeded {
                            Text(presentation.stateLabel)
                                .font(NovaType.caption)
                                .foregroundStyle(AgentActivityVisuals.tint(for: group.state))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                            Text("\u{00b7} \(presentation.durationLabel)")
                                .font(NovaType.caption)
                                .foregroundStyle(AgentPalette.tertiaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .opacity(canExpand ? 1 : 0)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                    }
                    .fixedSize(
                        horizontal: !dynamicTypeSize.isAccessibilitySize,
                        vertical: false
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canExpand)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AgentCanonicalActivityPresentation.accessibilitySummary(for: group)
        )
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(
            canExpand
                ? (isExpanded ? "Collapses activity details" : "Shows activity details")
                : "No additional activity details"
        )
        .accessibilityIdentifier("agentActivitySummary")
    }
}

/// One inexpensive text-only light sweep for the single active transcript row.
/// It does not allocate a glass layer, mask the full card, or animate completed
/// history. Reduce Motion and NovaForge performance mode both make it static.
private struct AgentActivityLiveSummaryText: View {
    let text: String
    let isLive: Bool
    let allowsMotion: Bool

    private var animates: Bool {
        isLive && allowsMotion && !AgentPerformance.prefersReducedVisualEffects
    }

    @ViewBuilder
    var body: some View {
        if animates {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                let cycle = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.8) / 1.8
                let center = cycle * 2.4 - 0.7
                Text(text)
                    .font(NovaType.body)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                AgentPalette.ink.opacity(0.74),
                                AgentPalette.ink,
                                AgentPalette.cyan,
                                AgentPalette.lilac,
                                AgentPalette.ink,
                                AgentPalette.ink.opacity(0.74),
                            ],
                            startPoint: UnitPoint(x: center - 0.32, y: 0.5),
                            endPoint: UnitPoint(x: center + 0.32, y: 0.5)
                        )
                    )
            }
        } else {
            Text(text)
                .font(NovaType.body)
                .foregroundStyle(AgentPalette.ink)
        }
    }
}

private struct AgentActivityCommandCluster: View {
    let group: AgentActivityGroup
    let glassNamespace: Namespace.ID
    let allowsMotion: Bool
    let send: (AgentActivityCommand) -> Void

    private var canStop: Bool {
        group.accepts(group.cancelCommand)
    }

    private var canRetry: Bool {
        group.accepts(group.retryCommand)
    }

    var body: some View {
        if canStop || canRetry {
            GlassGroup(spacing: 5) {
                HStack(spacing: 5) {
                    if canStop {
                        AgentActivityCommandButton(
                            title: "Stop",
                            hint: "Stops this run",
                            symbol: "stop.fill",
                            tint: AgentPalette.rose,
                            identifier: "agentActivityStop",
                            isProminent: true,
                            glassID: allowsMotion ? "agent-activity-stop" : nil,
                            glassNamespace: allowsMotion ? glassNamespace : nil,
                            action: { send(group.cancelCommand) }
                        )
                    }

                    if canRetry {
                        AgentActivityCommandButton(
                            title: "Retry",
                            hint: "Starts a new retry for this run",
                            symbol: "arrow.clockwise",
                            tint: AgentPalette.cyan,
                            identifier: "agentActivityRetry",
                            isProminent: true,
                            glassID: allowsMotion ? "agent-activity-retry" : nil,
                            glassNamespace: allowsMotion ? glassNamespace : nil,
                            action: { send(group.retryCommand) }
                        )
                    }
                }
            }
        }
    }
}

private struct AgentActivityCommandButton: View {
    let title: String
    let hint: String
    let symbol: String
    let tint: Color
    let identifier: String
    let isProminent: Bool
    let glassID: String?
    let glassNamespace: Namespace.ID?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: AgentDesign.minimumTouchTarget)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .contentShape(Circle())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.minimumTouchTarget / 2,
            tint: tint,
            selected: isProminent,
            glassID: glassID,
            in: glassNamespace
        )
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }
}

private struct AgentActivityDisclosureLane: View {
    let group: AgentActivityGroup
    let presentation: AgentCanonicalActivityPresentation
    let openReceipt: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Rectangle()
                .fill(AgentActivityVisuals.tint(for: group.state).opacity(0.30))
                .frame(width: 1)
                .padding(.vertical, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                if presentation.showsModelWork {
                    AgentActivityModelWorkView(
                        totalAttemptCount: group.attempts.count,
                        attempts: presentation.visibleAttempts,
                        hiddenAttemptCount: presentation.hiddenAttemptCount,
                        state: group.attempts.last?.state ?? group.state,
                        isExpanded: true
                    )
                }

                ForEach(presentation.visibleItems) { item in
                    AgentActivityItemRow(
                        item: item,
                        openFullDetail: openReceipt
                    )
                }

                if presentation.hiddenItemCount > 0 {
                    AgentActivityCappedNotice(
                        count: presentation.hiddenItemCount,
                        openFullDetail: openReceipt
                    )
                }

                if let error = group.errorMessage, !error.isEmpty,
                   !presentation.visibleItems.contains(where: { $0.errorMessage == error }) {
                    AgentActivityRunErrorView(
                        message: error,
                        openFullDetail: openReceipt
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 9)
    }
}
