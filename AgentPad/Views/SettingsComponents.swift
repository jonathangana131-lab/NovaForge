//
//  SettingsComponents.swift
//  Reusable Settings view components extracted from SettingsView.swift.
//  All structs are module-scope so SettingsView can construct them;
//  they take explicit parameters and hold no Settings-private state.
//

import SwiftUI

struct SettingsHero: View {
    let projectName: String
    let subtitle: String
    let tint: Color

    var body: some View {
        NovaScreenHeader(
            kicker: "Control // \(projectName)",
            title: "Control",
            subtitle: subtitle,
            symbol: "slider.horizontal.3",
            tint: tint
        )
    }
}

struct SettingsCommandDeck: View {
    let readinessTitle: String
    let readinessDetail: String
    let readinessSymbol: String
    let readinessTint: Color
    let providerName: String
    let providerSymbol: String
    let providerTint: Color
    let modelName: String
    let modelDetail: String
    let safetyTitle: String
    let safetyDetail: String
    let safetyTint: Color
    let buildLabel: String
    let buildDetail: String
    let theme: AgentTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: readinessSymbol)
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(readinessTint)
                    .frame(width: 48, height: 48)
                    .agentControlSurface(radius: 15, tint: readinessTint.opacity(0.14), selected: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Nova status")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)
                    Text(readinessTitle)
                        .font(.system(size: 24, weight: .black, design: AgentPalette.displayFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(readinessDetail)
                        .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCommandDeckBuildPill(label: buildLabel, detail: buildDetail)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                SettingsCommandDeckTile(
                    title: "Provider",
                    value: providerName,
                    detail: "Route",
                    symbol: providerSymbol,
                    tint: providerTint
                )

                SettingsCommandDeckTile(
                    title: "Model",
                    value: modelName,
                    detail: modelDetail,
                    symbol: "cpu",
                    tint: readinessTint
                )

                SettingsCommandDeckTile(
                    title: "Safety",
                    value: safetyTitle,
                    detail: safetyDetail,
                    symbol: safetyTitle == "Review first" ? "checkmark.shield.fill" : "bolt.badge.checkmark.fill",
                    tint: safetyTint
                )

                SettingsCommandDeckThemeTile(theme: theme)
            }
        }
        .padding(12)
        .agentSurface(radius: 20, tint: readinessTint.opacity(0.08))
    }
}

private struct SettingsCommandDeckBuildPill: View {
    let label: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 24, height: 24)
                .agentControlSurface(radius: 8, tint: AgentPalette.cyan.opacity(0.12), selected: false)

            Text("App build")
                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .textCase(.uppercase)

            Text(label)
                .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 4)

            Text(detail)
                .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .agentRowSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsBuildPill")
    }
}

private struct SettingsCommandDeckTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .agentControlSurface(radius: 8, tint: tint.opacity(0.12), selected: false)
                Text(title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Text(detail)
                .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .padding(10)
        .agentRowSurface(radius: 15, tint: tint.opacity(0.06))
    }
}

private struct SettingsCommandDeckThemeTile: View {
    let theme: AgentTheme

    private var palette: AgentThemePalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [palette.backgroundA, palette.backgroundB, palette.backgroundC],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Circle()
                        .fill(palette.primaryAccent)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 24, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.glassStroke, lineWidth: 0.8)
                )

                Text("Theme")
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }

            Text(theme.title)
                .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            HStack(spacing: 4) {
                Circle().fill(palette.primaryAccent).frame(width: 8, height: 8)
                Circle().fill(palette.secondaryAccent).frame(width: 8, height: 8)
                Circle().fill(palette.semanticSuccess).frame(width: 8, height: 8)
                Text("Selected")
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .padding(10)
        .agentRowSurface(radius: 15, tint: palette.primaryAccent.opacity(0.06))
    }
}

/// Flat settings band: tracked section mark + quiet subtitle, controls
/// sitting directly on the background. The old version wrapped every
/// section in an identical card, which flattened the whole screen into
/// card soup.
struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                NovaSectionMark(title: title)
                Text(subtitle)
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(2)
            }

            content
        }
        .padding(.top, 6)
    }
}


struct SettingsMetric: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(10)
        .agentSurface(radius: 16, tint: tint.opacity(0.08))
    }
}

struct SettingsStatusTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .agentControlSurface(radius: 9, tint: tint.opacity(0.12), selected: true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .allowsTightening(true)
                Text(value)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .agentRowSurface(radius: 14, tint: tint.opacity(0.06))
    }
}

struct SettingsProviderRow: View {
    let provider: AIProvider
    let selected: Bool
    let status: String
    let statusTint: Color
    let action: () -> Void

    var body: some View {
        Button {
            NovaHaptics.lensChanged()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: provider.symbol)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(provider.tint)
                        .frame(width: 30, height: 30)
                        .agentControlSurface(radius: 10, tint: provider.tint.opacity(0.13), selected: selected)

                    Spacer(minLength: 0)

                    ZStack {
                        Circle()
                            .strokeBorder(selected ? provider.tint : AgentPalette.quaternaryText.opacity(0.6), lineWidth: 1.3)
                            .frame(width: 16, height: 16)
                        if selected {
                            Circle()
                                .fill(provider.tint)
                                .frame(width: 8, height: 8)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName)
                        .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(selected ? AgentPalette.ink : AgentPalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                    Text(provider.subtitle)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }

                Text(status)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .agentControlSurface(radius: 7, tint: statusTint.opacity(0.11), selected: selected)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settingsProvider-\(provider.rawValue)")
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(selected ? provider.tint.opacity(0.13) : AgentPalette.controlFill.opacity(0.38))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    selected ? provider.tint.opacity(0.44) : AgentPalette.controlBorder.opacity(0.5),
                    lineWidth: 0.9
                )
        )
    }
}

struct SettingsMiniStat: Identifiable {
    let id: String
    let label: String
    let value: String

    init(label: String, value: String) {
        self.id = label
        self.label = label
        self.value = value
    }
}

struct SettingsModelReadinessPanel: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let stats: [SettingsMiniStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .agentControlSurface(radius: 12, tint: tint.opacity(0.13), selected: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Active model")
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)
                    Text(title)
                        .font(.system(size: 18, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.label)
                            .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .textCase(.uppercase)
                            .lineLimit(1)
                        Text(stat.value)
                            .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .padding(.horizontal, 8)
                    .agentControlSurface(radius: 10, tint: tint.opacity(0.07), selected: false)
                }
            }
        }
        .padding(12)
        .agentSurface(radius: 17, tint: tint.opacity(0.08))
        .accessibilityIdentifier("settingsModelReadinessPanel")
    }
}

struct SettingsSafetyModePicker: View {
    let autoApproveWrites: Bool
    let setMode: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                safetyButton(
                    title: "Review first",
                    detail: "Ask before writes, commands, or deletes",
                    symbol: "checkmark.shield.fill",
                    tint: AgentPalette.green,
                    selected: !autoApproveWrites,
                    value: false
                )
                safetyButton(
                    title: "Auto-approve",
                    detail: "Mutating sandbox tools skip prompts",
                    symbol: "bolt.badge.checkmark.fill",
                    tint: AgentPalette.warning,
                    selected: autoApproveWrites,
                    value: true
                )
            }

            Label(autoApproveWrites ? "Auto mode still records receipts, but file changes can happen without another stop." : "Review mode pauses before workspace mutations and keeps every decision recoverable.", systemImage: autoApproveWrites ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(autoApproveWrites ? AgentPalette.warning : AgentPalette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("settingsSafetyModePicker")
    }

    private func safetyButton(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        selected: Bool,
        value: Bool
    ) -> some View {
        Button {
            NovaHaptics.lensChanged()
            setMode(value)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(tint)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(tint)
                    }
                }
                Text(title)
                    .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                Text(detail)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .agentRowSurface(radius: 15, tint: tint.opacity(selected ? 0.13 : 0.05), selected: selected)
    }
}

struct SettingsDiagnosticItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
}

struct SettingsDiagnosticsPanel: View {
    let items: [SettingsDiagnosticItem]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(item.tint)
                        .frame(width: 32, height: 32)
                        .agentControlSurface(radius: 10, tint: item.tint.opacity(0.12), selected: false)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                                .lineLimit(1)
                            Text(item.value)
                                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(item.tint)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .agentControlSurface(radius: 6, tint: item.tint.opacity(0.10), selected: false)
                        }
                        Text(item.detail)
                            .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .agentRowSurface(radius: 14, tint: item.tint.opacity(0.05))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settingsDiagnostic-\(item.id)")
            }
        }
        .accessibilityIdentifier("settingsDiagnosticsPanel")
    }
}

struct LocalModelVariantRow: View {
    let variant: LocalModelVariant
    let selected: Bool
    let status: LocalModelStatus?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "cpu")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(selected ? AgentPalette.green : AgentPalette.secondaryText)
                    .frame(width: 34, height: 34)
                    .agentSurface(radius: 10, tint: selected ? AgentPalette.green.opacity(0.12) : nil)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(variant.displayName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        Text(variant.quantization)
                            .font(.caption2.monospacedDigit().weight(.black))
                            .foregroundStyle(AgentPalette.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .agentSurface(radius: 7, tint: AgentPalette.green.opacity(0.10))
                    }

                    Text("\(variant.expectedSizeLabel) · \(variant.executionLabel) · \(variant.contextTokens) context · \(variant.maxNewTokens) cap")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(variant.details)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if let status {
                    Text(status.title)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(statusColor(status))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .agentSurface(radius: 9, tint: statusColor(status).opacity(0.10))
                }
            }
            .padding(10)
            .agentSurface(radius: 14, tint: selected ? AgentPalette.green.opacity(0.10) : nil)
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ status: LocalModelStatus) -> Color {
        switch status {
        case .ready: AgentPalette.green
        case .downloading, .checking, .partial: AgentPalette.lilac
        case .missing: AgentPalette.secondaryText
        case .incompatible, .failed: AgentPalette.rose
        }
    }
}

struct LocalModelDownloadPanel: View {
    var manager: LocalModelManager
    @State private var pendingDestructiveAction: LocalModelDestructiveAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(statusColor)
                    .frame(width: 34, height: 34)
                    .agentSurface(radius: 10, tint: statusColor.opacity(0.12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.selectedVariant.shortName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    Text(statusDetail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            if manager.isDownloading || manager.isPartial {
                ProgressView(value: manager.progress.fraction)
                    .tint(AgentPalette.green)
                Text("\(bytes(manager.progress.receivedBytes)) of \(bytes(manager.progress.totalBytes))")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(AgentPalette.tertiaryText)
            }

            HStack(spacing: 10) {
                if manager.isDownloading {
                    SettingsActionButton(title: "Cancel", symbol: "xmark", tint: AgentPalette.rose, prominent: false) {
                        manager.cancelDownload()
                    }
                } else if manager.isDownloaded {
                    SettingsActionButton(title: "Ready", symbol: "checkmark.circle.fill", tint: AgentPalette.green, prominent: true) {
                        manager.refreshStatus()
                    }
                    .accessibilityIdentifier("settingsLocalModelReadyButton")
                    SettingsActionButton(title: "Remove", symbol: "trash", tint: AgentPalette.rose, prominent: false) {
                        pendingDestructiveAction = .remove
                    }
                    .accessibilityIdentifier("settingsLocalModelRemoveButton")
                } else if manager.isPartial {
                    SettingsActionButton(title: "Resume", symbol: "arrow.down.circle.fill", tint: AgentPalette.green, prominent: true) {
                        manager.downloadSelected()
                    }
                    .accessibilityIdentifier("settingsLocalModelResumeButton")
                    SettingsActionButton(title: "Restart", symbol: "arrow.clockwise", tint: AgentPalette.rose, prominent: false) {
                        pendingDestructiveAction = .restart
                    }
                    .accessibilityIdentifier("settingsLocalModelRestartButton")
                } else {
                    SettingsActionButton(title: "Download", symbol: "arrow.down.circle.fill", tint: AgentPalette.green, prominent: true) {
                        manager.downloadSelected()
                    }
                    .accessibilityIdentifier("settingsLocalModelDownloadButton")
                    .disabled(disableDownload)
                }
            }
        }
        .padding(12)
        .agentSurface(radius: 16, tint: AgentPalette.green.opacity(0.08))
        .alert(
            pendingDestructiveAction?.title ?? "Delete local model?",
            isPresented: Binding(
                get: { pendingDestructiveAction != nil },
                set: { if !$0 { pendingDestructiveAction = nil } }
            ),
            presenting: pendingDestructiveAction
        ) { action in
            Button(action.confirmTitle, role: .destructive) {
                manager.deleteSelectedModel()
                pendingDestructiveAction = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDestructiveAction = nil
            }
        } message: { action in
            Text(action.message)
        }
    }

    private var disableDownload: Bool {
        if case .incompatible = manager.status { return true }
        if case .checking = manager.status { return true }
        return false
    }

    private var statusSymbol: String {
        switch manager.status {
        case .ready: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle.fill"
        case .partial: "pause.circle.fill"
        case .incompatible, .failed: "exclamationmark.triangle.fill"
        case .checking: "hourglass"
        case .missing: "icloud.and.arrow.down"
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .ready: AgentPalette.green
        case .downloading, .checking: AgentPalette.lilac
        case .partial: AgentPalette.lilac
        case .missing: AgentPalette.cyan
        case .incompatible, .failed: AgentPalette.rose
        }
    }

    private var statusDetail: String {
        switch manager.status {
        case .ready:
            "Installed locally. Runs offline with capped context for smooth chat."
        case .downloading:
            "Downloading in the app model. You can switch tabs; keep NovaForge foregrounded."
        case .partial:
            "Download paused. Resume keeps the existing bytes instead of starting over."
        case .missing:
            "Download \(manager.selectedVariant.expectedSizeLabel) before using Local chat."
        case .checking:
            "Checking device storage and model file."
        case .incompatible(let message), .failed(let message):
            message
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private enum LocalModelDestructiveAction: String, Identifiable {
    case remove
    case restart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remove:
            "Remove local model?"
        case .restart:
            "Restart local model download?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .remove:
            "Remove Model"
        case .restart:
            "Restart Download"
        }
    }

    var message: String {
        switch self {
        case .remove:
            "This deletes the installed model and any partial download from this device. You can download it again later."
        case .restart:
            "This deletes the partial download and starts over from zero. Resume keeps existing bytes."
        }
    }
}

struct SettingsModelPickerButton: View {
    let provider: AIProvider
    let model: String
    let count: Int
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(provider.tint)
                    .frame(width: 40, height: 40)
                    .agentSurface(radius: 13, tint: provider.tint.opacity(0.10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(model)
                        .font(.system(.headline, design: AgentPalette.interfaceFontDesign, weight: .bold))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(isLoading ? "Loading provider model list…" : "Tap to browse \(count) \(count == 1 ? "model" : "models")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentPalette.secondaryText)
                }

                Spacer(minLength: 8)

                Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(provider.tint)
            }
            .padding(12)
            .agentSurface(radius: 16, tint: provider.tint.opacity(0.08))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("modelPickerButton")
    }
}

struct ProviderModelPickerSheet: View {
    let provider: AIProvider
    let models: [String]
    let selectedModel: String
    let isLoading: Bool
    let errorMessage: String?
    let refresh: () -> Void
    let select: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    private var filteredModels: [String] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(query) }
        return Array(matches.prefix(180))
    }

    private var hiddenModelCount: Int {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchCount = query.isEmpty ? models.count : models.lazy.filter { $0.localizedCaseInsensitiveContains(query) }.count
        return max(0, matchCount - filteredModels.count)
    }

    var body: some View {
        ZStack {
            sheetBackground

            VStack(spacing: 0) {
                Capsule()
                    .fill(AgentPalette.quaternaryText.opacity(0.55))
                    .frame(width: 42, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        hero
                        searchBar
                        refreshCard
                        modelList
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .task(id: searchText) {
            let value = searchText
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            debouncedSearchText = value
        }
        .onAppear {
            debouncedSearchText = searchText
            if models.count <= provider.modelOptions.count && !isLoading {
                refresh()
            }
        }
    }

    private var sheetBackground: some View {
        ZStack {
            LinearGradient(
                colors: [AgentPalette.surface, AgentPalette.pearl.opacity(0.96), provider.tint.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [provider.tint.opacity(0.24), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.symbol)
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(provider.tint)
                .frame(width: 48, height: 48)
                .background(provider.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Model")
                    .font(.system(size: 28, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text("\(provider.displayName) • \(models.count) choices")
                    .font(.system(size: 12, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(provider.tint)
                    .padding(.horizontal, 13)
                    .frame(minWidth: 58, minHeight: 48)
                    .background(provider.tint.opacity(0.10), in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("modelPickerDone")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(provider.tint)
            TextField("Search models", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16, weight: .semibold, design: AgentPalette.interfaceFontDesign))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .foregroundStyle(AgentPalette.tertiaryText)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Clear model search")
                .accessibilityIdentifier("settingsModelSearchClearButton")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 48)
        .background(AgentPalette.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AgentPalette.border.opacity(0.48), lineWidth: 0.8))
    }

    private var refreshCard: some View {
        Button(action: refresh) {
            HStack(spacing: 10) {
                Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "bolt.horizontal.circle.fill")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(provider.tint)
                    .frame(width: 30, height: 30)
                    .background(provider.tint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(isLoading ? "Refreshing provider models" : refreshCardTitle)
                        .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    Text(refreshCardDetail)
                        .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(errorMessage == nil ? AgentPalette.secondaryText : AgentPalette.rose)
                        .lineLimit(3)
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AgentPalette.secondaryText)
            }
            .foregroundStyle(AgentPalette.ink)
            .padding(12)
            .frame(minHeight: 58)
            .background(AgentPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AgentPalette.border.opacity(0.60), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .disabled(isLoading || provider == .local)
        .accessibilityIdentifier("modelRefreshButton")
    }

    private var refreshCardTitle: String {
        if provider == .openAICodex { return "Live ChatGPT models" }
        return errorMessage == nil ? "Live provider models" : "API key required"
    }

    private var refreshCardDetail: String {
        if provider == .openAICodex {
            return errorMessage ?? "Refreshes the GPT models currently enabled for your signed-in ChatGPT account."
        }
        if let errorMessage {
            if errorMessage.contains("Built-in model IDs are examples only") {
                return "API key needed. Built-in model IDs are examples only; add a key before running them."
            }
            return errorMessage
        }
        return provider == .local ? "Local models are managed on-device" : "Built-in model IDs are listed; an API key is still required to run."
    }

    private var modelList: some View {
        LazyVStack(spacing: 8) {
            ForEach(filteredModels, id: \.self) { model in
                modelRow(model)
            }
            if hiddenModelCount > 0 {
                Text("Showing first 180 matches. Keep typing to narrow \(hiddenModelCount) more.")
                    .font(.system(size: 12, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
        }
    }

    private func modelRow(_ model: String) -> some View {
        let selected = selectedModel == model
        return Button {
            if select(model) {
                dismiss()
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: modelSymbol(for: model))
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(selected ? provider.tint : AgentPalette.secondaryText)
                    .frame(width: 32, height: 32)
                    .background((selected ? provider.tint.opacity(0.14) : AgentPalette.row), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalModelCatalog.variant(for: model)?.shortName ?? model)
                        .font(.system(size: 15, weight: selected ? .black : .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(selected ? provider.tint : AgentPalette.quaternaryText)
            }
            .padding(11)
            .background((selected ? provider.tint.opacity(0.11) : AgentPalette.row), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(selected ? provider.tint.opacity(0.24) : AgentPalette.border.opacity(0.60), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func modelSymbol(for model: String) -> String {
        if LocalModelCatalog.variant(for: model) != nil { return "iphone.gen3" }
        if model.localizedCaseInsensitiveContains("codex") { return "terminal.fill" }
        if model.localizedCaseInsensitiveContains("gpt") { return "sparkles" }
        return "cube.transparent"
    }
}

struct SettingsChoiceButton: View {
    let title: String
    let selected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(selected ? AgentPalette.ink : AgentPalette.secondaryText)
            .padding(.horizontal, 10)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .agentSurface(radius: 13, tint: selected ? tint.opacity(0.13) : nil)
        }
        .buttonStyle(.plain)
    }
}

struct SettingsTextField: View {
    let title: String
    @Binding var text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AgentPalette.tertiaryText)
                .frame(width: 20)
            TextField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout)
        }
        .padding(12)
        .agentSurface(radius: 14)
    }
}

struct SettingsActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .agentSurface(radius: 14, tint: tint.opacity(prominent ? 0.18 : 0.08))
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? AgentPalette.ink : AgentPalette.secondaryText)
    }
}

struct ConnectionResultView: View {
    let result: Result<Void, Error>?

    var body: some View {
        if let result {
            switch result {
            case .success:
                Label("Connection success", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AgentPalette.green)
            case .failure(let error):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Connection failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AgentPalette.rose)
                    Text(error.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(AgentPalette.rose.opacity(0.85))
                        .lineLimit(4)
                }
            }
        }
    }
}

struct SettingsPresetRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .agentSurface(radius: 10, tint: tint.opacity(0.10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                }

                Spacer()

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tint)
                }
            }
            .foregroundStyle(AgentPalette.ink)
            .padding(10)
            .frame(minHeight: 58)
            .agentSurface(radius: 14, tint: selected ? tint.opacity(0.12) : nil)
        }
        .buttonStyle(.plain)
    }
}

struct SettingsThemeRow: View {
    let theme: AgentTheme
    let selected: Bool
    let action: () -> Void

    private var palette: AgentThemePalette { theme.palette }

    var body: some View {
        Button {
            NovaHaptics.lensChanged()
            action()
        } label: {
            HStack(spacing: 12) {
                themePreview

                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.title)
                        .font(NovaType.headline)
                        .foregroundStyle(AgentPalette.ink)
                    Text(theme.subtitle)
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .strokeBorder(selected ? palette.primaryAccent : AgentPalette.quaternaryText.opacity(0.6), lineWidth: 1.3)
                        .frame(width: 17, height: 17)
                    if selected {
                        Circle()
                            .fill(palette.primaryAccent)
                            .frame(width: 9, height: 9)
                    }
                }
            }
            .padding(10)
            .frame(minHeight: 68)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(selected ? palette.primaryAccent.opacity(0.09) : AgentPalette.controlFill.opacity(0.30))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    selected ? palette.primaryAccent.opacity(0.42) : AgentPalette.controlBorder.opacity(0.45),
                    lineWidth: 0.9
                )
        )
        .accessibilityIdentifier("settingsThemeRow-\(theme.rawValue)")
    }

    /// A miniature of the world itself: its canvas gradient, its accent
    /// light, and its own display face saying "Aa".
    private var themePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.backgroundB, palette.backgroundA, palette.backgroundC.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(palette.glassStroke, lineWidth: 0.8)
                )

            Text("Aa")
                .font(.system(size: 19, weight: .heavy, design: palette.typography.displayDesign))
                .foregroundStyle(palette.textPrimary)

            VStack {
                Spacer()
                HStack(spacing: 3) {
                    Capsule().fill(palette.primaryAccent).frame(width: 12, height: 3)
                    Circle().fill(palette.secondaryAccent).frame(width: 3, height: 3)
                    Circle().fill(palette.semanticSuccess).frame(width: 3, height: 3)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 6)
            }
        }
        .frame(width: 62, height: 48)
        .accessibilityHidden(true)
    }
}

struct SettingsThemeStudioCard: View {
    let theme: AgentTheme
    let selected: Bool
    let action: () -> Void

    private var palette: AgentThemePalette { theme.palette }

    var body: some View {
        Button {
            NovaHaptics.lensChanged()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                studioPreview

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(theme.title)
                        .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)

                    Spacer(minLength: 0)

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(palette.primaryAccent)
                    }
                }

                Text(theme.subtitle)
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    swatch(palette.primaryAccent)
                    swatch(palette.secondaryAccent)
                    swatch(palette.semanticSuccess)
                    swatch(palette.semanticWarning)
                    Spacer(minLength: 0)
                    Text(selected ? "Active" : "Preview")
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(selected ? palette.primaryAccent : AgentPalette.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(selected ? palette.primaryAccent.opacity(0.10) : AgentPalette.controlFill.opacity(0.30))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    selected ? palette.primaryAccent.opacity(0.46) : AgentPalette.controlBorder.opacity(0.45),
                    lineWidth: 0.9
                )
        )
        .shadow(color: selected ? palette.glow.opacity(0.20) : .clear, radius: 12, x: 0, y: 6)
        .accessibilityIdentifier("settingsThemeStudioCard-\(theme.rawValue)")
    }

    private var studioPreview: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.backgroundA, palette.backgroundB, palette.backgroundC, palette.backgroundD],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(palette.glow)
                .frame(width: 56, height: 56)
                .blur(radius: 14)
                .offset(x: 82, y: -32)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    Text("Aa")
                        .font(.system(size: 24, weight: .heavy, design: palette.typography.displayDesign))
                        .foregroundStyle(palette.textPrimary)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.primaryAccent)
                        .frame(width: 26, height: 9)
                }

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.textSecondary.opacity(0.78))
                        .frame(width: 76, height: 5)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.textTertiary.opacity(0.64))
                        .frame(width: 52, height: 5)
                }

                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.surface.opacity(0.88))
                        .frame(height: 16)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.controlFillSelected.opacity(0.90))
                        .frame(width: 34, height: 16)
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.glassStroke, lineWidth: 0.9)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    private func swatch(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(AgentPalette.border.opacity(0.45), lineWidth: 0.5))
    }
}

struct SettingsResetButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive) {
            action()
        } label: {
            Label("Reset Workspace", systemImage: "trash")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .agentSurface(radius: 14, tint: AgentPalette.rose.opacity(0.13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AgentPalette.rose)
    }
}

struct SettingsSaveToast: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AgentPalette.green)
                Text("Saved")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AgentPalette.ink)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .agentSurface(radius: 12, tint: AgentPalette.green.opacity(0.14))
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .top)
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }
}
