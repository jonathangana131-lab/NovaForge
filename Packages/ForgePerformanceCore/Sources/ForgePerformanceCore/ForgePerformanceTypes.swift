import Foundation

public enum ForgePerformanceError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case unsupportedSchema(Int)
    case collectionTooLarge(field: String, maximum: Int)
    case invalidMetric(field: String)
    case invalidPolicy(String)
    case duplicateScenarioID(String)
    case duplicateRunID(String)
    case duplicateProducerReceiptID(String)
    case duplicateTrustedProducerReceiptID(String)
    case duplicateScenarioEvidence(String)
    case targetMismatch(String)
    case unknownScenario(String)
}

enum ForgePerformanceValidation {
    static func identifier(_ value: String, field: String, maximumLength: Int = 512) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed, !value.isEmpty, value.count <= maximumLength else {
            throw ForgePerformanceError.invalidIdentifier(field)
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgePerformanceError.invalidIdentifier(field)
        }
        return value
    }

    static func maximumCount(_ count: Int, field: String, maximum: Int) throws {
        guard count <= maximum else {
            throw ForgePerformanceError.collectionTooLarge(field: field, maximum: maximum)
        }
    }

    static func finiteNonnegative(_ value: Double, field: String) throws -> Double {
        guard value.isFinite, value >= 0 else {
            throw ForgePerformanceError.invalidMetric(field: field)
        }
        return value
    }
}

public struct ForgePerformanceTarget: Codable, Equatable, Hashable, Sendable {
    public let projectID: String
    public let sourceRevision: String
    public let checkpointID: String
    public let runtimeVersion: String

    public init(projectID: String, sourceRevision: String, checkpointID: String, runtimeVersion: String) throws {
        self.projectID = try ForgePerformanceValidation.identifier(projectID, field: "target.projectID", maximumLength: 256)
        self.sourceRevision = try ForgePerformanceValidation.identifier(sourceRevision, field: "target.sourceRevision")
        self.checkpointID = try ForgePerformanceValidation.identifier(checkpointID, field: "target.checkpointID", maximumLength: 256)
        self.runtimeVersion = try ForgePerformanceValidation.identifier(runtimeVersion, field: "target.runtimeVersion", maximumLength: 256)
    }

    private enum CodingKeys: String, CodingKey { case projectID, sourceRevision, checkpointID, runtimeVersion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: c.decode(String.self, forKey: .projectID),
            sourceRevision: c.decode(String.self, forKey: .sourceRevision),
            checkpointID: c.decode(String.self, forKey: .checkpointID),
            runtimeVersion: c.decode(String.self, forKey: .runtimeVersion)
        )
    }
}

public enum ForgePerformanceExecutionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case simulator
    case physicalDevice
}

public struct ForgePerformanceExecutionContext: Codable, Equatable, Hashable, Sendable {
    public let kind: ForgePerformanceExecutionKind
    public let deviceIdentifier: String
    public let osName: String
    public let osVersion: String
    public let osBuild: String

    public init(kind: ForgePerformanceExecutionKind, deviceIdentifier: String, osName: String, osVersion: String, osBuild: String) throws {
        self.kind = kind
        self.deviceIdentifier = try ForgePerformanceValidation.identifier(deviceIdentifier, field: "execution.deviceIdentifier", maximumLength: 128)
        self.osName = try ForgePerformanceValidation.identifier(osName, field: "execution.osName", maximumLength: 64)
        self.osVersion = try ForgePerformanceValidation.identifier(osVersion, field: "execution.osVersion", maximumLength: 64)
        self.osBuild = try ForgePerformanceValidation.identifier(osBuild, field: "execution.osBuild", maximumLength: 128)
    }

    private enum CodingKeys: String, CodingKey { case kind, deviceIdentifier, osName, osVersion, osBuild }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: c.decode(ForgePerformanceExecutionKind.self, forKey: .kind),
            deviceIdentifier: c.decode(String.self, forKey: .deviceIdentifier),
            osName: c.decode(String.self, forKey: .osName),
            osVersion: c.decode(String.self, forKey: .osVersion),
            osBuild: c.decode(String.self, forKey: .osBuild)
        )
    }
}
