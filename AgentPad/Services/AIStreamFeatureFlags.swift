import Foundation

enum AIStreamFeatureFlags {
    static let responseStageLaunchArgument = "--ai-response-stage"
    static let semanticStreamLaunchArgument = "--semantic-ai-stream"
    static let proofStageLaunchArgument = "--new-ai-streaming-stage"
    static let proofStageDemoLaunchArgument = "--new-ai-streaming-stage-demo"
    static let legacyResponseLaunchArgument = "--legacy-ai-stream"
    static let responseStageDefaultsKey = "AIResponseStageEnabled"

    static let responseStageEnabled: Bool = {
        resolveResponseStageEnabled(
            launchFlags: launchFlags,
            persistedOverride: UserDefaults.standard.object(forKey: responseStageDefaultsKey) as? Bool
        )
    }()

    static let semanticStreamEnabled: Bool = {
        // The semantic reducer remains an opt-in diagnostics/proof path. The
        // production stage renders the already display-paced Forge feed so the
        // app never advances two independent text timelines at once.
        hasLaunchFlag(semanticStreamLaunchArgument) ||
            hasLaunchFlag(proofStageLaunchArgument) ||
            hasLaunchFlag(proofStageDemoLaunchArgument)
    }()

    /// Resolves explicit process arguments before the persisted preference so
    /// UI tests and proof captures cannot be silently disabled by an older
    /// value in UserDefaults. The explicit legacy escape hatch remains the
    /// strongest signal when contradictory arguments are supplied.
    static func resolveResponseStageEnabled(
        launchFlags: Set<String>,
        persistedOverride: Bool?
    ) -> Bool {
        if launchFlags.contains(legacyResponseLaunchArgument) {
            return false
        }

        if !launchFlags.isDisjoint(with: positiveStageLaunchFlags) {
            return true
        }

        return persistedOverride ?? true
    }

    private static func hasLaunchFlag(_ flag: String) -> Bool {
        launchFlags.contains(flag)
    }

    private static let positiveStageLaunchFlags: Set<String> = [
        responseStageLaunchArgument,
        semanticStreamLaunchArgument,
        proofStageLaunchArgument,
        proofStageDemoLaunchArgument
    ]

    /// Process arguments never change after launch. Normalize them once rather
    /// than joining and scanning the full argument list from rendering paths.
    private static let launchFlags: Set<String> = {
        var flags = Set<String>()
        for argument in ProcessInfo.processInfo.arguments {
            for token in argument.split(whereSeparator: { $0.isWhitespace }) {
                let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                if name.hasPrefix("--") {
                    flags.insert(name)
                }
            }
        }
        return flags
    }()
}
