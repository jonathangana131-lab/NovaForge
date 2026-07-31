import AgentDomain
import AgentPolicy
import SwiftUI

/// The safety-critical decision surface shared by Forge and every local
/// mutation entry point. It accepts only the broker's redacted projection;
/// raw arguments, command text, file contents, and provider output are not in
/// this view's type system.
struct AgentApprovalDecisionView: View {
    let item: AgentApprovalPromptCenter.PendingItem
    let queuedRequestCount: Int
    let approve: () -> Void
    let reject: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsTechnicalDetails = false
    @Namespace private var glassNamespace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading
                consequenceCard
                targetDetails

                if queuedRequestCount > 0 {
                    queuedNotice
                }

                technicalDisclosure
                decisionControls
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(AgentBackground(isAnimated: false))
        .navigationTitle("Review change")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("agentPolicyApprovalView")
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle()
                    .fill(tint.opacity(reduceTransparency ? 0.24 : 0.15))
                Circle()
                    .strokeBorder(tint.opacity(0.34), lineWidth: 0.7)
                Image(systemName: operationSymbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(operationTitle)
                    .font(.system(.title2, design: AgentPalette.displayFontDesign, weight: .bold))
                    .foregroundStyle(AgentPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("NovaForge is paused until you approve or reject this exact workspace change.")
                    .font(.system(.subheadline, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Approval required. \(operationTitle). NovaForge is paused.")
    }

    private var consequenceCard: some View {
        let headingLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))

        return VStack(alignment: .leading, spacing: 12) {
            headingLayout {
                Label(riskTitle, systemImage: riskSymbol)
                    .font(.system(.subheadline, design: AgentPalette.interfaceFontDesign, weight: .bold))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                expiryLabel
            }

            Text(consequence)
                .font(.system(.body, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Label("The decision is bound to this request, tool, workspace, and content digest.", systemImage: "checkmark.seal.fill")
                .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .semibold))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .agentSurface(
            radius: AgentDesign.cardRadius,
            // Native Liquid Glass treats its tint as a material color, not as
            // a subtle accent. Keep the semantic hue but lower its material
            // density so the heading and receipt text retain contrast in
            // bright themes such as White Gold.
            tint: tint.opacity(0.10),
            nativeGlass: !reduceTransparency
        )
        // The expiry is a changing readout and must remain independently
        // discoverable. Containing the children also preserves the visible
        // receipt-binding statement for VoiceOver instead of replacing it with
        // a shorter custom label.
        .accessibilityElement(children: .contain)
    }

    private var expiryLabel: some View {
        return TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let seconds = max(
                0,
                Int(item.expiresAt.date.timeIntervalSince(timeline.date).rounded(.down))
            )
            Label(Self.duration(seconds), systemImage: "timer")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(seconds == 0 ? AgentPalette.rose : AgentPalette.secondaryText)
                .accessibilityLabel(seconds == 0 ? "Approval expired" : "Expires in \(Self.duration(seconds))")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("agentPolicyApprovalExpiry")
        }
    }

    private var targetDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What will change")
                .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .bold))
                .foregroundStyle(AgentPalette.tertiaryText)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(detailRows.enumerated()), id: \.offset) { _, row in
                HStack(
                    alignment: dynamicTypeSize.isAccessibilitySize ? .top : .firstTextBaseline,
                    spacing: 11
                ) {
                    Image(systemName: row.symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(row.tint)
                        .frame(width: 20)
                        .padding(.top, dynamicTypeSize.isAccessibilitySize ? 3 : 0)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .semibold))
                            .foregroundStyle(AgentPalette.secondaryText)
                        Text(row.value)
                            .font(.system(.subheadline, design: row.monospaced ? .monospaced : AgentPalette.interfaceFontDesign, weight: .semibold))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                            .truncationMode(.middle)
                            .fixedSize(
                                horizontal: false,
                                vertical: dynamicTypeSize.isAccessibilitySize
                            )
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .agentRowSurface(radius: AgentDesign.rowRadius, tint: row.tint)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.label), \(row.value)")
            }
        }
    }

    private var queuedNotice: some View {
        Label(
            "\(queuedRequestCount) more change\(queuedRequestCount == 1 ? "" : "s") waiting for review",
            systemImage: "list.bullet.rectangle"
        )
        .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .semibold))
        .foregroundStyle(AgentPalette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .agentRowSurface(radius: AgentDesign.rowRadius, tint: AgentPalette.cyan)
        .accessibilityIdentifier("agentPolicyApprovalQueuedCount")
    }

    private var technicalDisclosure: some View {
        DisclosureGroup(isExpanded: $showsTechnicalDetails) {
            VStack(alignment: .leading, spacing: 8) {
                technicalRow("Tool", "\(item.toolName) · v\(item.toolVersion)")
                technicalRow("Source", originTitle)
                technicalRow("Request", Self.shortIdentity(item.requestID.description))
                technicalRow("Preview", Self.shortDigest(item.previewSHA256.rawValue))
                technicalRow("Binding", Self.shortDigest(item.bindingSHA256.rawValue))
            }
            .padding(.top, 10)
        } label: {
            Label("Technical identity", systemImage: "number.square")
                .font(.system(.subheadline, design: AgentPalette.interfaceFontDesign, weight: .semibold))
                .foregroundStyle(AgentPalette.secondaryText)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
        }
        .tint(AgentPalette.cyan)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .agentRowSurface(radius: AgentDesign.rowRadius, tint: AgentPalette.cyan)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: showsTechnicalDetails)
        .accessibilityIdentifier("agentPolicyApprovalTechnicalDisclosure")
    }

    private func technicalRow(_ label: String, _ value: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))

        return layout {
            Text(label)
                .foregroundStyle(AgentPalette.tertiaryText)
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    alignment: .leading
                )

            Text(value)
                .foregroundStyle(AgentPalette.secondaryText)
                .textSelection(.enabled)
                .multilineTextAlignment(
                    dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
                )
                .fixedSize(
                    horizontal: false,
                    vertical: dynamicTypeSize.isAccessibilitySize
                )
                .frame(
                    maxWidth: .infinity,
                    alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
                )
        }
        .font(.system(.caption2, design: .monospaced, weight: .medium))
    }

    private var decisionControls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))

        return TimelineView(.periodic(from: .now, by: 1)) { timeline in
            GlassGroup(spacing: 12) {
                layout {
                    decisionButton(
                        title: "Reject",
                        symbol: "xmark",
                        tint: AgentPalette.rose,
                        identifier: "agentPolicyRejectButton",
                        action: reject
                    )
                    decisionButton(
                        title: approveTitle,
                        symbol: "checkmark",
                        tint: AgentPalette.green,
                        identifier: "agentPolicyApproveButton",
                        isDisabled: item.expiresAt.date <= timeline.date,
                        action: approve
                    )
                }
            }
        }
    }

    private func decisionButton(
        title: String,
        symbol: String,
        tint: Color,
        identifier: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            NovaHaptics.tick()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(.headline, design: AgentPalette.interfaceFontDesign, weight: .bold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .contentShape(Capsule())
        }
        .agentInteractiveGlassButtonStyle(
            radius: 26,
            tint: tint,
            selected: true,
            glassID: identifier,
            in: glassNamespace
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
        .accessibilityLabel(title)
        .accessibilityHint(
            isDisabled
                ? "This approval request has expired"
                : title == "Reject"
                    ? "Rejects this exact change without applying it"
                    : "Approves only this exact change"
        )
        .accessibilityIdentifier(identifier)
    }
}

private extension AgentApprovalDecisionView {
    struct DetailRow {
        let label: String
        let value: String
        let symbol: String
        let tint: Color
        var monospaced = false
    }

    var detailRows: [DetailRow] {
        switch item.operation {
        case let .writeFile(path, bytes):
            return [pathRow(path), sizeRow(bytes, label: "New contents")]
        case let .appendFile(path, bytes):
            return [pathRow(path), sizeRow(bytes, label: "Appended text")]
        case let .replaceText(path, scope, matchedBytes, replacementBytes):
            return [
                pathRow(path),
                DetailRow(
                    label: "Replacement scope",
                    value: scope == .everyMatch ? "Every exact match" : "One unambiguous match",
                    symbol: "text.badge.checkmark",
                    tint: AgentPalette.cyan
                ),
                sizeRow(matchedBytes, label: "Matched text"),
                sizeRow(replacementBytes, label: "Replacement text"),
            ]
        case let .deletePath(path):
            return [pathRow(path, tint: AgentPalette.rose)]
        case let .movePath(source, destination):
            return [pathRow(source, label: "From"), pathRow(destination, label: "To")]
        case let .copyPath(source, destination):
            return [pathRow(source, label: "From"), pathRow(destination, label: "Copy to")]
        case let .makeDirectory(path):
            return [pathRow(path, label: "New folder")]
        case let .runCommand(bytes):
            return [
                DetailRow(
                    label: "Allowlisted command",
                    value: "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)) command · exact text hidden here",
                    symbol: "terminal.fill",
                    tint: AgentPalette.warning
                ),
            ]
        case let .createFile(path):
            return [pathRow(path, label: "New file")]
        case let .touchFile(path):
            return [pathRow(path, label: "File")]
        case .resetWorkspace:
            return [
                DetailRow(
                    label: "Scope",
                    value: "Entire current workspace",
                    symbol: "externaldrive.badge.xmark",
                    tint: AgentPalette.rose
                ),
            ]
        case let .seedWorkspace(targets):
            var rows = targets.prefix(3).map {
                DetailRow(
                    label: "Seed file",
                    value: "\($0.path) · \(ByteCountFormatter.string(fromByteCount: Int64($0.contentUTF8ByteCount), countStyle: .memory))",
                    symbol: "doc.badge.plus",
                    tint: AgentPalette.cyan,
                    monospaced: true
                )
            }
            if targets.count > 3 {
                rows.append(DetailRow(
                    label: "Additional files",
                    value: "\(targets.count - 3) more exact targets",
                    symbol: "ellipsis",
                    tint: AgentPalette.secondaryText
                ))
            }
            return rows
        }
    }

    func pathRow(
        _ path: String,
        label: String = "Workspace target",
        tint: Color = AgentPalette.cyan
    ) -> DetailRow {
        DetailRow(
            label: label,
            value: path,
            symbol: "doc.text",
            tint: tint,
            monospaced: true
        )
    }

    func sizeRow(_ bytes: Int, label: String) -> DetailRow {
        DetailRow(
            label: label,
            value: ByteCountFormatter.string(
                fromByteCount: Int64(bytes),
                countStyle: .memory
            ),
            symbol: "textformat.size",
            tint: AgentPalette.lilac
        )
    }

    var operationTitle: String {
        switch item.operation {
        case .writeFile: "Write file"
        case .appendFile: "Append to file"
        case .replaceText: "Replace text"
        case .deletePath: "Delete workspace item"
        case .movePath: "Move workspace item"
        case .copyPath: "Copy workspace item"
        case .makeDirectory: "Create folder"
        case .runCommand: "Run workspace command"
        case .createFile: "Create file"
        case .touchFile: "Update file timestamp"
        case .resetWorkspace: "Reset workspace"
        case .seedWorkspace: "Seed workspace"
        }
    }

    var operationSymbol: String {
        switch item.operation {
        case .writeFile, .appendFile, .replaceText: "pencil.and.outline"
        case .deletePath, .resetWorkspace: "trash.fill"
        case .movePath: "arrowshape.turn.up.right.fill"
        case .copyPath: "doc.on.doc.fill"
        case .makeDirectory: "folder.badge.plus"
        case .runCommand: "terminal.fill"
        case .createFile, .touchFile, .seedWorkspace: "doc.badge.plus"
        }
    }

    var consequence: String {
        switch item.operation {
        case .writeFile:
            "Approving replaces the target file with the exact reviewed content and records a recoverable receipt."
        case .appendFile:
            "Approving adds the exact reviewed text to the target file and records the resulting evidence."
        case .replaceText:
            "Approving changes only the exact matched text in the target file."
        case .deletePath:
            "Approving removes the target from the workspace after a checkpoint is captured."
        case .movePath:
            "Approving moves the exact source to the exact destination after both targets are revalidated."
        case .copyPath:
            "Approving creates the reviewed destination from the exact source."
        case .makeDirectory:
            "Approving creates the exact folder inside this workspace."
        case .runCommand:
            "Approving runs one parsed, allowlisted workspace command without a shell."
        case .createFile:
            "Approving creates one empty file at the exact target."
        case .touchFile:
            "Approving updates the exact file through the protected mutation boundary."
        case .resetWorkspace:
            "Approving removes every item in the current workspace after a protected checkpoint."
        case .seedWorkspace:
            "Approving writes the listed seed files as one receipt-bound workspace change."
        }
    }

    var riskTitle: String {
        switch item.effectClass {
        case .scopedReversibleWrite: "Scoped, checkpointed change"
        case .broadOrDestructiveWrite: "Destructive change"
        case .externalSideEffect: "External side effect"
        case .credentialBearingOrPrivileged: "Privileged action"
        case .unrecoverableDenied: "Blocked action"
        case .readOnlyLocal: "Local read"
        }
    }

    var riskSymbol: String {
        switch item.effectClass {
        case .scopedReversibleWrite: "arrow.uturn.backward.circle.fill"
        case .broadOrDestructiveWrite: "exclamationmark.triangle.fill"
        case .externalSideEffect: "network.badge.shield.half.filled"
        case .credentialBearingOrPrivileged: "key.fill"
        case .unrecoverableDenied: "nosign"
        case .readOnlyLocal: "eye.fill"
        }
    }

    var tint: Color {
        switch item.effectClass {
        case .scopedReversibleWrite: AgentPalette.approval
        case .broadOrDestructiveWrite, .unrecoverableDenied: AgentPalette.rose
        case .externalSideEffect, .credentialBearingOrPrivileged: AgentPalette.warning
        case .readOnlyLocal: AgentPalette.cyan
        }
    }

    var approveTitle: String {
        if case .resetWorkspace = item.operation { return "Reset" }
        if case .deletePath = item.operation { return "Delete" }
        return "Approve"
    }

    var originTitle: String {
        switch item.origin {
        case .agentV2: "Agent V2"
        case .v1Fallback: "Legacy agent fallback"
        case .editor: "Code editor"
        case .files: "Files"
        case .terminal: "Terminal"
        case .artifact: "Artifact save"
        case .control: "Control"
        case .projectOS: "ProjectOS"
        case .trustedSystem: "NovaForge system"
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds <= 0 { return "Expired" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }

    static func shortIdentity(_ value: String) -> String {
        value.count > 12 ? String(value.suffix(12)) : value
    }

    static func shortDigest(_ value: String) -> String {
        let raw = value.hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
        guard raw.count > 16 else { return raw }
        return "\(raw.prefix(8))…\(raw.suffix(8))"
    }
}
