//
//  RunActivityController.swift
//  NovaForge
//
//  Bridges agent run state into ActivityKit (Live Activity + Dynamic Island)
//  and keeps the home-screen widget snapshot fresh. Fails silent and cheap
//  when activities aren't authorized — runs never depend on it.
//

import ActivityKit
import Foundation
import WidgetKit

@MainActor
final class RunActivityController {
    static let shared = RunActivityController()

    private var activity: Activity<NovaRunActivityAttributes>?
    private var lastStatusLine = ""
    private var lastWidgetHeadline = ""
    private var lastWidgetSync = Date.distantPast

    // MARK: - Live Activity lifecycle

    func runStarted(projectName: String, statusLine: String) {
        let state = NovaRunActivityAttributes.ContentState(
            phase: "Build",
            statusLine: statusLine,
            isWorking: true,
            startedAt: Date()
        )
        lastStatusLine = statusLine
        if let activity {
            nonisolated(unsafe) let live = activity
            Task { await live.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: NovaRunActivityAttributes(projectName: projectName),
            content: ActivityContent(state: state, staleDate: nil)
        )
    }

    func runProgressed(phase: String, statusLine: String) {
        guard let activity, statusLine != lastStatusLine else { return }
        lastStatusLine = statusLine
        let previous = activity.content.state
        let state = NovaRunActivityAttributes.ContentState(
            phase: phase,
            statusLine: statusLine,
            isWorking: true,
            startedAt: previous.startedAt
        )
        nonisolated(unsafe) let live = activity
        Task { await live.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func runEnded(statusLine: String, success: Bool) {
        guard let activity else { return }
        self.activity = nil
        lastStatusLine = ""
        let previous = activity.content.state
        let state = NovaRunActivityAttributes.ContentState(
            phase: success ? "Prove" : "Blocked",
            statusLine: statusLine,
            isWorking: false,
            startedAt: previous.startedAt
        )
        nonisolated(unsafe) let live = activity
        Task {
            await live.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(6))
            )
        }
    }

    // MARK: - Widget snapshot

    /// Throttled: at most one write + timeline reload per 20s unless the
    /// headline changed, so hot run loops never spam WidgetKit.
    func syncWidgetSnapshot(projectName: String, statusHeadline: String, journeyPhase: String, proofCount: Int) {
        let now = Date()
        guard statusHeadline != lastWidgetHeadline || now.timeIntervalSince(lastWidgetSync) > 20 else { return }
        lastWidgetHeadline = statusHeadline
        lastWidgetSync = now
        NovaWidgetSharedState.write(.init(
            projectName: projectName,
            statusHeadline: statusHeadline,
            journeyPhase: journeyPhase,
            proofCount: proofCount,
            updatedAt: now
        ))
        WidgetCenter.shared.reloadTimelines(ofKind: "NovaForgeProjectStatus")
    }
}
