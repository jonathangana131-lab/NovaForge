//
//  NovaForgeSharedActivity.swift
//  NovaForge / NovaForgeWidgets (compiled into both targets)
//
//  Shared vocabulary between the app and its widget extension: the Live
//  Activity attributes for agent runs, and the home-screen widget snapshot.
//

import ActivityKit
import Foundation

// MARK: - Live Activity attributes

struct NovaRunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var statusLine: String
        var isWorking: Bool
        var startedAt: Date
    }

    var projectName: String
}

// MARK: - Home-screen widget snapshot

enum NovaWidgetSharedState {
    static let suiteName = "group.com.joey.NovaForge"
    static let snapshotKey = "novaWidgetSnapshot"

    struct Snapshot: Codable, Equatable {
        var projectName: String
        var statusHeadline: String
        var journeyPhase: String
        var proofCount: Int
        var updatedAt: Date
    }

    /// App-group defaults when entitled; standard defaults otherwise so the
    /// call sites never branch. Without the entitlement the widget simply
    /// renders its sample content — honest, never broken.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func write(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func read() -> Snapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
