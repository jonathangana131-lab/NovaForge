//
//  ProjectStatusWidget.swift
//  NovaForgeWidgets
//
//  Home-screen project status: name, current state, Plan→Build→Prove journey
//  rail, and the proof count. Reads the app-written snapshot; renders an
//  honest sample when none exists yet.
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
                    NovaWidgetPalette.canvas
                }
        }
        .configurationDisplayName("Project Status")
        .description("Your NovaForge project's journey and latest proof at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

enum NovaWidgetPalette {
    static let canvas = Color(red: 0.045, green: 0.055, blue: 0.09)
    static let ink = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.38)
    static let cyan = Color(red: 0.42, green: 0.78, blue: 1.0)
    static let green = Color(red: 0.42, green: 0.9, blue: 0.6)
    static let lilac = Color(red: 0.72, green: 0.62, blue: 1.0)
}

struct ProjectStatusWidgetView: View {
    let entry: ProjectStatusEntry
    @Environment(\.widgetFamily) private var family

    private var phases: [String] { ["Plan", "Build", "Prove"] }

    private var activePhaseIndex: Int {
        phases.firstIndex(of: entry.snapshot.journeyPhase) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(NovaWidgetPalette.cyan)
                Text(entry.snapshot.projectName)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(NovaWidgetPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(entry.snapshot.statusHeadline)
                .font(.system(size: family == .systemSmall ? 12 : 14, weight: .bold))
                .foregroundStyle(NovaWidgetPalette.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            journeyRail

            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(entry.snapshot.proofCount > 0 ? NovaWidgetPalette.green : NovaWidgetPalette.tertiary)
                Text(entry.snapshot.proofCount > 0 ? "\(entry.snapshot.proofCount) proof\(entry.snapshot.proofCount == 1 ? "" : "s")" : "No proof yet")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NovaWidgetPalette.secondary)
                Spacer(minLength: 0)
                Text(entry.snapshot.updatedAt, style: .relative)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(NovaWidgetPalette.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.snapshot.projectName): \(entry.snapshot.statusHeadline). Phase \(entry.snapshot.journeyPhase).")
    }

    private var journeyRail: some View {
        HStack(spacing: 4) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                HStack(spacing: 3) {
                    Circle()
                        .fill(index <= activePhaseIndex ? NovaWidgetPalette.cyan : NovaWidgetPalette.tertiary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    if family != .systemSmall || index == activePhaseIndex {
                        Text(phase)
                            .font(.system(size: 8.5, weight: index == activePhaseIndex ? .black : .semibold))
                            .foregroundStyle(index == activePhaseIndex ? NovaWidgetPalette.cyan : NovaWidgetPalette.tertiary)
                    }
                }
                if index < phases.count - 1 {
                    Rectangle()
                        .fill(index < activePhaseIndex ? NovaWidgetPalette.cyan.opacity(0.6) : NovaWidgetPalette.tertiary.opacity(0.25))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
