import SwiftUI

/// Compact transcript handoff for a broker-owned approval.
///
/// Only the projection-owned public summary and classified action metadata are
/// shown here. The exact approve/reject decision remains in the redacted safety
/// surface reached through `review`.
struct AgentActivityApprovalReviewView: View {
    let approval: AgentActivityApproval
    let action: AgentActivityItem?
    let review: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsDetails = false

    private var hasDetails: Bool {
        action != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            approvalControls

            if showsDetails, let action {
                AgentActivityApprovalDetail(action: action)
                    .padding(.leading, 27)
                    .padding(.bottom, 3)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 9)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(AgentPalette.warning.opacity(0.48))
                .frame(width: 2)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
        }
        .animation(
            NovaMotion.enabled(reduceMotion: reduceMotion)
                ? .smooth(duration: 0.14)
                : nil,
            value: showsDetails
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentActivityApproval")
    }

    private var approvalControls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 7))

        return layout {
            AgentActivityApprovalSummaryButton(
                approval: approval,
                isExpanded: showsDetails,
                canExpand: hasDetails,
                toggle: toggleDetails
            )

            Button(action: reviewApproval) {
                Label("Review", systemImage: "checkmark.shield")
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.warning)
                    .padding(.horizontal, 11)
                    .frame(
                        maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                        minHeight: AgentDesign.minimumTouchTarget,
                        alignment: .leading
                    )
            }
            .agentInteractiveGlassButtonStyle(
                radius: AgentDesign.minimumTouchTarget / 2,
                tint: AgentPalette.warning,
                selected: true
            )
            .accessibilityLabel("Review approval")
            .accessibilityHint("Shows the exact change with approve and reject controls")
            .accessibilityIdentifier("agentActivityReviewApproval")
        }
    }

    private func toggleDetails() {
        guard hasDetails else { return }
        NovaHaptics.tick()
        showsDetails.toggle()
    }

    private func reviewApproval() {
        review()
    }
}

private struct AgentActivityApprovalSummaryButton: View {
    let approval: AgentActivityApproval
    let isExpanded: Bool
    let canExpand: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 7) {
                AgentActivityStateGlyph(state: .awaitingApproval, size: 20)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Approval required")
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.warning)

                    Text(approval.publicSummary)
                        .font(NovaType.body)
                        .foregroundStyle(AgentPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .opacity(canExpand ? 1 : 0)
                    .frame(width: 12, height: 20)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canExpand)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Approval required. \(approval.publicSummary)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(
            canExpand
                ? (isExpanded ? "Hides the public action summary" : "Shows the public action summary")
                : "Use Review to inspect and decide"
        )
        .accessibilityIdentifier("agentActivityApprovalSummary")
    }
}

private struct AgentActivityApprovalDetail: View {
    let action: AgentActivityItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            AgentActivityDetailLine(
                symbol: AgentActivityVisuals.symbol(for: action.kind),
                title: "Action",
                value: action.summary,
                tint: AgentPalette.warning
            )

            if let target = action.target, !target.isEmpty {
                AgentActivityDetailLine(
                    symbol: "scope",
                    title: "Target",
                    value: target,
                    tint: AgentPalette.cyan
                )
            }

            Label(
                "Review the exact target, risk, and consequence before deciding.",
                systemImage: "checkmark.seal"
            )
            .font(NovaType.caption)
            .foregroundStyle(AgentPalette.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}

struct AgentActivityCoalescedNotice: View {
    let count: Int

    var body: some View {
        Label(
            "\(count) earlier action\(count == 1 ? "" : "s") complete",
            systemImage: "checkmark.circle"
        )
        .font(NovaType.caption)
        .foregroundStyle(AgentPalette.tertiaryText)
        .padding(.leading, 27)
        .frame(minHeight: 28)
        .accessibilityIdentifier("agentActivityCoalescedCount")
    }
}

struct AgentActivityCappedNotice: View {
    let count: Int
    let openFullDetail: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 7))

        layout {
            Text("\(count) earlier item\(count == 1 ? "" : "s") in History")
                .font(NovaType.caption)
                .foregroundStyle(AgentPalette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: openFullDetail) {
                Label("Open", systemImage: "clock.arrow.circlepath")
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.cyan)
                    .padding(.horizontal, 10)
                    .frame(minHeight: AgentDesign.minimumTouchTarget)
            }
            .agentInteractiveGlassButtonStyle(
                radius: AgentDesign.minimumTouchTarget / 2,
                tint: AgentPalette.cyan
            )
            .accessibilityLabel("Open earlier activity in History")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentActivityCappedCount")
    }
}

struct AgentArtifactHandoffList: View {
    let artifacts: [AgentActivityArtifact]
    let hiddenArtifactCount: Int
    let openArtifact: (AgentActivityArtifact) -> Void
    let openFullDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Artifacts", systemImage: "paperclip")
                .font(NovaType.caption)
                .foregroundStyle(AgentPalette.tertiaryText)
                .padding(.leading, 27)
                .frame(minHeight: 26)
                .accessibilityAddTraits(.isHeader)

            ForEach(artifacts) { artifact in
                AgentArtifactHandoffView(
                    artifact: artifact,
                    open: { openArtifact(artifact) }
                )
            }

            if hiddenArtifactCount > 0 {
                Button(action: openFullDetail) {
                    Label(
                        "\(hiddenArtifactCount) more in History",
                        systemImage: "ellipsis.circle"
                    )
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.cyan)
                    .padding(.horizontal, 11)
                    .frame(minHeight: AgentDesign.minimumTouchTarget)
                }
                .agentInteractiveGlassButtonStyle(
                    radius: AgentDesign.minimumTouchTarget / 2,
                    tint: AgentPalette.cyan
                )
                .padding(.leading, 27)
                .accessibilityLabel(
                    "Open \(hiddenArtifactCount) more artifact\(hiddenArtifactCount == 1 ? "" : "s") in History"
                )
                .accessibilityIdentifier("agentActivityMoreArtifacts")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct AgentArtifactHandoffView: View {
    let artifact: AgentActivityArtifact
    let open: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 7))

        layout {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "doc.badge.checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AgentPalette.cyan)
                    .frame(width: 18)
                    .padding(.top, dynamicTypeSize.isAccessibilitySize ? 3 : 0)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(artifact.displayName)
                        .font(NovaType.body)
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .truncationMode(.middle)
                        .fixedSize(
                            horizontal: false,
                            vertical: dynamicTypeSize.isAccessibilitySize
                        )

                    Text("Ready to open")
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: open) {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AgentPalette.cyan)
                    .frame(width: AgentDesign.minimumTouchTarget)
                    .frame(minHeight: AgentDesign.minimumTouchTarget)
                    .contentShape(Circle())
            }
            .agentInteractiveGlassButtonStyle(
                radius: AgentDesign.minimumTouchTarget / 2,
                tint: AgentPalette.cyan
            )
            .accessibilityLabel("Open \(artifact.displayName)")
            .accessibilityHint("Opens this artifact handoff")
            .frame(
                maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                alignment: .trailing
            )
        }
        .padding(.leading, 27)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AgentPalette.divider.opacity(AgentDesign.dividerOpacity))
                .frame(height: 0.5)
                .padding(.leading, 25)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentActivityArtifact")
    }
}
