//
//  RunActivityWidget.swift
//  NovaForgeWidgets
//
//  Live Activity for agent runs: lock-screen banner plus Dynamic Island
//  presentation with the journey phase and the current status line.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct NovaRunActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NovaRunActivityAttributes.self) { context in
            // Lock screen / banner
            HStack(spacing: 10) {
                Image(systemName: context.state.isWorking ? "waveform" : "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(context.state.isWorking ? NovaWidgetPalette.cyan : NovaWidgetPalette.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.projectName)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(NovaWidgetPalette.secondary)
                        .lineLimit(1)
                    Text(context.state.statusLine)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(NovaWidgetPalette.ink)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.state.phase)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(NovaWidgetPalette.cyan)
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(NovaWidgetPalette.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            .padding(14)
            .activityBackgroundTint(NovaWidgetPalette.canvas)
            .activitySystemActionForegroundColor(NovaWidgetPalette.cyan)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: context.state.isWorking ? "waveform" : "checkmark.seal.fill")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(context.state.isWorking ? NovaWidgetPalette.cyan : NovaWidgetPalette.green)
                        Text(context.state.phase)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(NovaWidgetPalette.ink)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(NovaWidgetPalette.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.projectName)
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(NovaWidgetPalette.secondary)
                            .lineLimit(1)
                        Text(context.state.statusLine)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(NovaWidgetPalette.ink)
                            .lineLimit(2)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isWorking ? "waveform" : "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(context.state.isWorking ? NovaWidgetPalette.cyan : NovaWidgetPalette.green)
            } compactTrailing: {
                Text(context.state.phase)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(NovaWidgetPalette.cyan)
            } minimal: {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(NovaWidgetPalette.cyan)
            }
        }
    }
}
