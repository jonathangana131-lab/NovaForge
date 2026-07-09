import Foundation

enum AIStreamFeatureFlags {
    static let responseStageLaunchArgument = "--ai-response-stage"
    static let semanticStreamLaunchArgument = "--semantic-ai-stream"
    static let proofStageLaunchArgument = "--new-ai-streaming-stage"
    static let proofStageDemoLaunchArgument = "--new-ai-streaming-stage-demo"
    static let responseStageDefaultsKey = "AIResponseStageEnabled"

    static var responseStageEnabled: Bool {
        hasLaunchFlag(responseStageLaunchArgument) ||
            hasLaunchFlag(semanticStreamLaunchArgument) ||
            hasLaunchFlag(proofStageLaunchArgument) ||
            hasLaunchFlag(proofStageDemoLaunchArgument) ||
            UserDefaults.standard.bool(forKey: responseStageDefaultsKey)
    }

    static var semanticStreamEnabled: Bool {
        responseStageEnabled
    }

    private static func hasLaunchFlag(_ flag: String) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(flag) ||
            arguments.joined(separator: " ").contains(flag) ||
            arguments.contains { argument in
                argument == flag ||
                    argument.hasPrefix("\(flag)=") ||
                    argument.split(whereSeparator: { $0.isWhitespace }).contains(Substring(flag))
            }
    }
}
