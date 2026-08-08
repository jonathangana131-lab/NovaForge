import Foundation

public enum VisualAcceptanceEvidenceError: Error, Equatable, Sendable {
    case invalidEnvironmentIdentity
    case invalidRuntimeCapture
    case invalidAccessibilityObservation
    case duplicateAccessibilityCheck
    case invalidAccessibilityPolicy
    case invalidPerformanceSample
    case duplicateOrUnorderedFrameOrdinal
    case tooManyPerformanceSamples
    case invalidPerformancePolicy
}

public enum VisualExecutionEnvironmentKind: String, Codable, CaseIterable, Sendable {
    case simulator
    case physicalDevice
}

public struct VisualExecutionEnvironmentIdentity: Codable, Equatable, Hashable, Sendable {
    public let kind: VisualExecutionEnvironmentKind
    public let deviceModelIdentifier: String
    public let osVersion: String
    public let runtimeVersion: String

    public init(
        kind: VisualExecutionEnvironmentKind,
        deviceModelIdentifier: String,
        osVersion: String,
        runtimeVersion: String
    ) throws {
        guard Self.valid(deviceModelIdentifier), Self.valid(osVersion), Self.valid(runtimeVersion) else {
            throw VisualAcceptanceEvidenceError.invalidEnvironmentIdentity
        }
        self.kind = kind
        self.deviceModelIdentifier = deviceModelIdentifier
        self.osVersion = osVersion
        self.runtimeVersion = runtimeVersion
    }

    private static func valid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 160
    }

    private enum CodingKeys: String, CodingKey { case kind, deviceModelIdentifier, osVersion, runtimeVersion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: values.decode(VisualExecutionEnvironmentKind.self, forKey: .kind),
            deviceModelIdentifier: values.decode(String.self, forKey: .deviceModelIdentifier),
            osVersion: values.decode(String.self, forKey: .osVersion),
            runtimeVersion: values.decode(String.self, forKey: .runtimeVersion)
        )
    }
}
