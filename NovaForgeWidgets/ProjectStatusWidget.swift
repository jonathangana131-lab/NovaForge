//
//  ProjectStatusWidget.swift
//  NovaForgeWidgets
//
//  Home-screen project status in the facelift HUD language: reticle mark,
//  tracked kicker, display-weight status line, journey rail, and the proof
//  count as an instrument numeral. Reads the app-written snapshot; renders
//  an honest sample when none exists yet.
//

import SwiftUI
import WidgetKit

struct ProjectStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: NovaWidgetSharedState.Snapshot
    let isSample: Bool

    static var sample: ProjectStatusEntry {
        ProjectStatusEntry(
            date: .now,
            snapshot: .init(
                projectName: "NovaForge Project",
                statusHeadline: "Ready for the next command",
                journeyPhase: "Plan",
                proofCount: 0,
                updatedAt: .now
            ),
            isSample: true
        )
    }
}

struct ProjectStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProjectStatusEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (ProjectStatusEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProjectStatusEntry>) -> Void) {
        let entry = currentEntry()
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1_800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func currentEntry() -> ProjectStatusEntry {
        if let snapshot = NovaWidgetSharedState.read() {
            return ProjectStatusEntry(date: .now, snapshot: snapshot, isSample: false)
        }
        return .sample
    }
}

struct ProjectStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NovaForgeProjectStatus", provider: ProjectStatusProvider()) { entry in
            ProjectStatusWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    ZStack {
                        NovaWidgetPalette.canvas
                        RadialGradient(
                            colors: [NovaWidgetPalette.cyan.opacity(0.10), .clear],
                            center: .topTrailing,
                            startRadius: 0,
                            endRadius: 190
                        )
                    }
                }
        }
        .configurationDisplayName("Project Status")
        .description("Your NovaForge project's journey and latest proof at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

enum NovaWidgetPalette {
    static let canvas = Color(red: 0.030, green: 0.038, blue: 0.062)
    static let ink = Color.white.opacity(0.95)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let cyan = Color(red: 0.46, green: 0.80, blue: 1.0)
    static let green = Color(red: 0.42, green: 0.9, blue: 0.6)
    static let lilac = Color(red: 0.72, green: 0.62, blue: 1.0)
}

/// Reticle mini-mark shared across the widget family.
struct NovaWidgetReticle: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            Circle()
                .trim(from: 0.05, to: 0.20)
                .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .rotationEffect(.degrees(12))
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ProjectStatusWidgetView: View {
    let entry: ProjectStatusEntry
    @Environment(\.widgetFamily) private var family

    private var phases: [String] { ["Plan", "Build", "Prove"] }

    private var activePhaseIndex: Int {
        phases.firstIndex(of: entry.snapshot.journeyPhase) ?? 0
    }

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 5 : 7) {
            HStack(spacing: 6) {
                NovaWidgetReticle(symbol: "sparkles", tint: NovaWidgetPalette.cyan, size: isSmall ? 18 : 21)
                Text(entry.snapshot.projectName.uppercased())
                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(NovaWidgetPalette.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }

            Text(entry.snapshot.statusHeadline)
                .font(.system(size: isSmall ? 14 : 17, weight: .heavy, design: .rounded))
                .foregroundStyle(NovaWidgetPalette.ink)
                .lineLimit(isSmall ? 3 : 2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            journeyRail

            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text("\(entry.snapshot.proofCount)")
                    .font(.system(size: isSmall ? 15 : 17, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(entry.snapshot.proofCount > 0 ? NovaWidgetPalette.green : NovaWidgetPalette.tertiary)
                Text("PROOF")
                    .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(entry.snapshot.proofCount > 0 ? NovaWidgetPalette.secondary : NovaWidgetPalette.tertiary)
                Spacer(minLength: 0)
                Text(entry.snapshot.updatedAt, style: .relative)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(NovaWidgetPalette.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.snapshot.projectName): \(entry.snapshot.statusHeadline). Phase \(entry.snapshot.journeyPhase). \(entry.snapshot.proofCount) proof items.")
    }

    private var journeyRail: some View {
        HStack(spacing: 4) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                HStack(spacing: 3.5) {
                    ZStack {
                        if index == activePhaseIndex {
                            Circle()
                                .fill(NovaWidgetPalette.cyan.opacity(0.28))
                                .frame(width: 10, height: 10)
                        }
                        Circle()
                            .fill(index <= activePhaseIndex ? NovaWidgetPalette.cyan : NovaWidgetPalette.tertiary.opacity(0.4))
                            .frame(width: 5, height: 5)
                    }
                    if !isSmall || index == activePhaseIndex {
                        Text(phase.uppercased())
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(index == activePhaseIndex ? NovaWidgetPalette.cyan : NovaWidgetPalette.tertiary)
                    }
                }
                if index < phases.count - 1 {
                    Rectangle()
                        .fill(index < activePhaseIndex ? NovaWidgetPalette.cyan.opacity(0.55) : NovaWidgetPalette.tertiary.opacity(0.25))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
