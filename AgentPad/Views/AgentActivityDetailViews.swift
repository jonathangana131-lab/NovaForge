import SwiftUI

enum AgentActivityVisuals {
    static func tint(for state: AgentActivityState) -> Color {
        switch state {
        case .pending, .queued: AgentPalette.secondaryText
        case .running, .retrying: AgentPalette.cyan
        case .awaitingApproval: AgentPalette.warning
        case .succeeded: AgentPalette.green
        case .failed, .rejected, .interrupted: AgentPalette.rose
        case .cancelling, .cancelled: AgentPalette.secondaryText
        }
    }

    static func symbol(for state: AgentActivityState) -> String {
        switch state {
        case .pending: "hourglass"
        case .queued: "clock"
        case .running: "waveform"
        case .awaitingApproval: "checkmark.shield"
        case .retrying: "arrow.clockwise"
        case .succeeded: "checkmark"
        case .failed: "xmark"
        case .rejected: "hand.raised"
        case .cancelling: "stop"
        case .cancelled: "stop.fill"
        case .interrupted: "bolt.slash"
        }
    }

    static func symbol(for kind: AgentActivitySemanticKind) -> String {
        switch kind {
        case .modelAttempt: "brain.head.profile"
        case .plan: "checklist"
        case .tool: "wrench.and.screwdriver"
        case .approval: "checkmark.shield"
        case .retry: "arrow.clockwise"
        case .routeChange: "arrow.triangle.branch"
        case .checkpoint: "archivebox"
        case .cancellation: "stop.circle"
        case .failure: "exclamationmark.triangle"
        }
    }
}

/// A deliberately small status mark. It is content, not chrome, so it never
/// allocates a blur or native glass layer in a scrolling transcript.
struct AgentActivityStateGlyph: View {
    let state: AgentActivityState
    let size: CGFloat
    var symbol: String? = nil

    var body: some View {
        let tint = AgentActivityVisuals.tint(for: state)
        ZStack {
            Circle()
                .fill(tint.opacity(0.13))
            Circle()
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.6)
            Image(systemName: symbol ?? AgentActivityVisuals.symbol(for: state))
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(
            AgentCanonicalActivityPresentation.stateLabel(for: state)
        )
    }
}

struct AgentActivityModelWorkView: View {
    let totalAttemptCount: Int
    let attempts: [AgentActivityAttempt]
    let hiddenAttemptCount: Int
    let state: AgentActivityState
    let isExpanded: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let contentLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 7))

        VStack(alignment: .leading, spacing: 2) {
            HStack(
                alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
                spacing: 7
            ) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AgentActivityVisuals.tint(for: state))
                    .frame(width: 18)
                    .padding(.top, dynamicTypeSize.isAccessibilitySize ? 3 : 0)
                    .accessibilityHidden(true)

                contentLayout {
                    Text(
                        AgentCanonicalActivityPresentation.attemptSummary(
                            count: totalAttemptCount
                        )
                    )
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(
                        horizontal: false,
                        vertical: dynamicTypeSize.isAccessibilitySize
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    AgentActivityStateLabel(state: state)
                }
            }
            .frame(minHeight: 32)

            if isExpanded {
                ForEach(attempts) { attempt in
                    AgentActivityAttemptRow(
                        attempt: attempt,
                        ordinal: ordinal(for: attempt)
                    )
                }

                if hiddenAttemptCount > 0 {
                    Text("\(hiddenAttemptCount) earlier model attempt\(hiddenAttemptCount == 1 ? "" : "s") in History")
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 25)
                        .frame(minHeight: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: isExpanded ? .contain : .combine)
        .accessibilityLabel(
            "\(AgentCanonicalActivityPresentation.attemptSummary(count: totalAttemptCount)). \(AgentCanonicalActivityPresentation.stateLabel(for: state))."
        )
        .accessibilityIdentifier("agentActivityModelWork")
    }

    private func ordinal(for attempt: AgentActivityAttempt) -> Int {
        let visibleOffset = attempts.firstIndex(where: { $0.id == attempt.id }) ?? 0
        return max(1, totalAttemptCount - attempts.count + visibleOffset + 1)
    }
}

private struct AgentActivityAttemptRow: View {
    let attempt: AgentActivityAttempt
    let ordinal: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let contentLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 7))

        HStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
            spacing: 7
        ) {
            Image(systemName: AgentActivityVisuals.symbol(for: attempt.state))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AgentActivityVisuals.tint(for: attempt.state))
                .frame(width: 18)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 3 : 0)
                .accessibilityHidden(true)

            contentLayout {
                Text("Attempt \(ordinal)")
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 7) {
                    Text(
                        AgentCanonicalActivityPresentation.durationLabel(
                            milliseconds: attempt.span.durationMilliseconds
                        )
                    )
                    .font(NovaType.readoutSmall)
                    .foregroundStyle(AgentPalette.tertiaryText)

                    AgentActivityStateLabel(state: attempt.state)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.leading, 25)
        .frame(minHeight: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Attempt \(ordinal). \(AgentCanonicalActivityPresentation.stateLabel(for: attempt.state)). \(AgentCanonicalActivityPresentation.durationLabel(milliseconds: attempt.span.durationMilliseconds))."
        )
    }
}

struct AgentActivityItemRow: View {
    let item: AgentActivityItem
    let openFullDetail: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsDetail = false

    var body: some View {
        let contentLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 7))

        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleDetail) {
                HStack(
                    alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
                    spacing: 7
                ) {
                    Image(
                        systemName: AgentCanonicalActivityPresentation
                            .activitySymbol(for: item)
                    )
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AgentActivityVisuals.tint(for: item.state))
                        .frame(width: 18)
                        .padding(.top, dynamicTypeSize.isAccessibilitySize ? 3 : 0)
                        .accessibilityHidden(true)

                    contentLayout {
                        Text(
                            AgentCanonicalActivityPresentation
                                .activityLabel(for: item)
                        )
                            .font(NovaType.body)
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .truncationMode(.middle)
                            .fixedSize(
                                horizontal: false,
                                vertical: dynamicTypeSize.isAccessibilitySize
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)

                        HStack(spacing: 7) {
                            AgentActivityStateLabel(state: item.state)

                            Text(
                                AgentCanonicalActivityPresentation.durationLabel(
                                    milliseconds: item.span.durationMilliseconds
                                )
                            )
                            .font(NovaType.caption)
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AgentPalette.tertiaryText)
                                .rotationEffect(.degrees(showsDetail ? 180 : 0))
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AgentCanonicalActivityPresentation.accessibilitySummary(for: item)
            )
            .accessibilityValue(showsDetail ? "Expanded" : "Collapsed")
            .accessibilityHint(
                showsDetail ? "Collapses item detail" : "Shows item detail"
            )

            if showsDetail {
                AgentActivityDetailView(
                    item: item,
                    openFullDetail: openFullDetail
                )
                .padding(.bottom, 5)
                .transition(.opacity)
            }
        }
        .animation(
            NovaMotion.enabled(reduceMotion: reduceMotion)
                ? .smooth(duration: 0.14)
                : nil,
            value: showsDetail
        )
        .accessibilityIdentifier("agentActivityItem")
    }

    private func toggleDetail() {
        NovaHaptics.tick()
        showsDetail.toggle()
    }
}

struct AgentActivityDetailView: View {
    let item: AgentActivityItem
    let openFullDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = item.target, !target.isEmpty {
                AgentActivityDetailLine(
                    symbol: "scope",
                    title: "Target",
                    value: target,
                    tint: AgentPalette.cyan
                )
            }

            AgentActivityDetailLine(
                symbol: AgentActivityVisuals.symbol(for: item.state),
                title: "Outcome",
                value: AgentCanonicalActivityPresentation.stateLabel(for: item.state),
                tint: AgentActivityVisuals.tint(for: item.state)
            )

            if !item.evidenceIDs.isEmpty {
                AgentActivityDetailLine(
                    symbol: "checkmark.seal",
                    title: "Evidence",
                    value: "\(item.evidenceIDs.count) verified record\(item.evidenceIDs.count == 1 ? "" : "s")",
                    tint: AgentPalette.green
                )
            }

            if !item.artifactIDs.isEmpty {
                AgentActivityDetailLine(
                    symbol: "doc.badge.checkmark",
                    title: "Artifacts",
                    value: "\(item.artifactIDs.count) handoff\(item.artifactIDs.count == 1 ? "" : "s")",
                    tint: AgentPalette.cyan
                )
            }

            if let error = item.errorMessage, !error.isEmpty {
                AgentActivityInlineError(message: error)
            }

            Button(action: openFullDetail) {
                Label("Open receipt", systemImage: "doc.text.magnifyingglass")
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.cyan)
                    .padding(.horizontal, 11)
                    .frame(minHeight: AgentDesign.minimumTouchTarget)
            }
            .agentInteractiveGlassButtonStyle(
                radius: AgentDesign.controlRadius,
                tint: AgentPalette.cyan
            )
            .accessibilityHint("Opens uncapped evidence and diagnostics in History")
            .accessibilityIdentifier("agentActivityItemReceipt")
        }
        .padding(.leading, 25)
    }
}

struct AgentActivityDetailLine: View {
    let symbol: String
    let title: String
    let value: String
    let tint: Color

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let contentLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 7))

        HStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .top : .firstTextBaseline,
            spacing: 7
        ) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 3 : 0)
                .accessibilityHidden(true)

            contentLayout {
                Text(title)
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .frame(
                        width: dynamicTypeSize.isAccessibilitySize ? nil : 58,
                        alignment: .leading
                    )

                Text(value)
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    .truncationMode(.middle)
                    .fixedSize(
                        horizontal: false,
                        vertical: dynamicTypeSize.isAccessibilitySize
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AgentActivityRunErrorView: View {
    let message: String
    let openFullDetail: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AgentPalette.rose)
                .frame(width: 18, height: 24)
                .accessibilityHidden(true)

            Text(message)
                .font(NovaType.caption)
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                .fixedSize(
                    horizontal: false,
                    vertical: dynamicTypeSize.isAccessibilitySize
                )
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: openFullDetail) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AgentPalette.rose)
                    .frame(width: AgentDesign.minimumTouchTarget)
                    .frame(minHeight: AgentDesign.minimumTouchTarget)
            }
            .agentInteractiveGlassButtonStyle(
                radius: AgentDesign.minimumTouchTarget / 2,
                tint: AgentPalette.rose
            )
            .accessibilityLabel("Open failed run receipt")
            .accessibilityHint("Opens uncapped diagnostics in History")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AgentActivityInlineError: View {
    let message: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AgentPalette.rose)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(message)
                .font(NovaType.caption)
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
                .fixedSize(
                    horizontal: false,
                    vertical: dynamicTypeSize.isAccessibilitySize
                )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AgentActivityStateLabel: View {
    let state: AgentActivityState

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Text(AgentCanonicalActivityPresentation.stateLabel(for: state))
            .font(.system(.caption2, design: AgentPalette.interfaceFontDesign, weight: .bold))
            .foregroundStyle(AgentActivityVisuals.tint(for: state))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .accessibilityLabel(
                AgentCanonicalActivityPresentation.stateLabel(for: state)
            )
    }
}
