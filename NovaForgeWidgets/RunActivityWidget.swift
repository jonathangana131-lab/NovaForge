//
//  RunActivityWidget.swift
//  NovaForgeWidgets
//
//  Live Activity for agent runs in the facelift HUD language: reticle
//  status mark, tracked phase label, hero timer numerals — on the lock
//  screen and in every Dynamic Island presentation.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct NovaRunActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NovaRunActivityAttributes.self) { context in
            // Lock screen / banner
            HStack(spacing: 12) {
                NovaWidgetReticle(
                    symbol: context.state.isWorking ? "waveform" : "checkmark.seal.fill",
                    tint: context.state.isWorking ? NovaWidgetPalette.cyan : NovaWidgetPalette.green,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(context.attributes.projectName.uppercased())
                            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(NovaWidgetPalette.tertiary)
                            .lineLimit(1)
                        Text(context.state.phase.uppercased())
                            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                            .tracking(1.0)
                            .foregroundStyle(NovaWidgetPalette.cyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(NovaWidgetPalette.cyan.opacity(0.14))
                            )
                    }
                    Text(context.state.statusLine)
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(NovaWidgetPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 17, weight: .heavy, design: .monospaced))
                        .foregroundStyle(context.state.isWorking ? NovaWidgetPalette.cyan : NovaWidgetPalette.green)
                        .frame(width: 62, alignment: .trailing)
                    Text("ELAPSED")
                        .font(.system(size: 6.5, weight: .heavy, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(NovaWidgetPalette.tertiary)
                }
            }
            .padding(15)
            .activityBackgroundTint(NovaWidgetPalette.canvas)
            .activitySystemActionForegroundColor(NovaWidgetPalette.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        NovaWidgetReticle(
                            symbol: context.state.isWorking ? "waveform" : "checkmark.seal.fill",
                            tint: context.state.isWorking ? NovaWidgetPalette.cyan : NovaWidgetPalette.green,
                            size: 26
                        )
                        Text(context.state.phase.uppercased())
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(1.0)
                            .foregroundStyle(NovaWidgetPalette.ink)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .foregroundStyle(NovaWidgetPalette.cyan)
                        .frame(width: 54, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.projectName.uppercased())
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(NovaWidgetPalette.tertiary)
                            .lineLimit(1)
                        Text(context.state.statusLine)
                            .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(NovaWidgetPalette.ink)
                            .lineLimit(2)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isWorking ? "waveform" : "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(context.state.isWorking ? NovaWidgetPalette.cyan : NovaWidgetPalette.green)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(NovaWidgetPalette.cyan)
                    .frame(width: 38)
            } minimal: {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NovaWidgetPalette.cyan)
            }
        }
    }
}
