import Foundation

public enum LocalAIQualificationError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidContextTokens
    case invalidMetric(String)
    case invalidTaskSuite
    case duplicateTaskID(String)
    case profileMismatch
    case revisionNotIncreasing
    case archiveSchemaUnsupported(Int)
    case archiveProfileMismatch
    case emptyArchive
}

func validatedIdentifier(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.utf8.count <= 256,
          !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
        throw LocalAIQualificationError.invalidIdentifier(field)
    }
    return trimmed
}

public struct LocalAIModelIdentity: Codable, Hashable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let tokenizerID: String
    public let tokenizerRevision: String

    public init(
        modelID: String,
        modelRevision: String,
        tokenizerID: String,
        tokenizerRevision: String
    ) throws {
        self.modelID = try validatedIdentifier(modelID, field: "modelID")
        self.modelRevision = try validatedIdentifier(modelRevision, field: "modelRevision")
        self.tokenizerID = try validatedIdentifier(tokenizerID, field: "tokenizerID")
        self.tokenizerRevision = try validatedIdentifier(tokenizerRevision, field: "tokenizerRevision")
    }

    private enum CodingKeys: String, CodingKey {
        case modelID, modelRevision, tokenizerID, tokenizerRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelID: container.decode(String.self, forKey: .modelID),
            modelRevision: container.decode(String.self, forKey: .modelRevision),
            tokenizerID: container.decode(String.self, forKey: .tokenizerID),
            tokenizerRevision: container.decode(String.self, forKey: .tokenizerRevision)
        )
    }
}

public enum LocalAIBackend: String, Codable, Hashable, Sendable {
    case cpu
    case metal
    case cpuAndMetal
}

public enum LocalAIKVCacheType: Codable, Hashable, Sendable {
    case fp16
    case q8
    case q4
    case custom(String)

    fileprivate func validated() throws -> Self {
        switch self {
        case .fp16, .q8, .q4:
            return self
        case let .custom(value):
            return .custom(try validatedIdentifier(value, field: "kvCacheType"))
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case fp16, q8, q4, custom }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .fp16: self = .fp16
        case .q8: self = .q8
        case .q4: self = .q4
        case .custom:
            self = .custom(try validatedIdentifier(
                container.decode(String.self, forKey: .value),
                field: "kvCacheType"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fp16: try container.encode(Kind.fp16, forKey: .kind)
        case .q8: try container.encode(Kind.q8, forKey: .kind)
        case .q4: try container.encode(Kind.q4, forKey: .kind)
        case let .custom(value):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(try validatedIdentifier(value, field: "kvCacheType"), forKey: .value)
        }
    }
}

public enum LocalAIWeightLoadingMode: String, Codable, Hashable, Sendable {
    case resident
    case memoryMapped
    case flashStreamingExperimental
    case sparseExpertPagingExperimental

    public var isExperimental: Bool {
        switch self {
        case .resident, .memoryMapped: false
        case .flashStreamingExperimental, .sparseExpertPagingExperimental: true
        }
    }
}

public struct LocalAIRuntimeProfile: Codable, Hashable, Sendable {
    public let runtimeID: String
    public let runtimeRevision: String
    public let backend: LocalAIBackend
    public let quantization: String
    public let kvCacheType: LocalAIKVCacheType
    public let contextTokens: Int
    public let weightLoadingMode: LocalAIWeightLoadingMode

    public init(
        runtimeID: String,
        runtimeRevision: String,
        backend: LocalAIBackend,
        quantization: String,
        kvCacheType: LocalAIKVCacheType,
        contextTokens: Int,
        weightLoadingMode: LocalAIWeightLoadingMode
    ) throws {
        self.runtimeID = try validatedIdentifier(runtimeID, field: "runtimeID")
        self.runtimeRevision = try validatedIdentifier(runtimeRevision, field: "runtimeRevision")
        self.backend = backend
        self.quantization = try validatedIdentifier(quantization, field: "quantization")
        guard (128...1_048_576).contains(contextTokens) else {
            throw LocalAIQualificationError.invalidContextTokens
        }
        self.kvCacheType = try kvCacheType.validated()
        self.contextTokens = contextTokens
        self.weightLoadingMode = weightLoadingMode
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeID, runtimeRevision, backend, quantization, kvCacheType, contextTokens, weightLoadingMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runtimeID: container.decode(String.self, forKey: .runtimeID),
            runtimeRevision: container.decode(String.self, forKey: .runtimeRevision),
            backend: container.decode(LocalAIBackend.self, forKey: .backend),
            quantization: container.decode(String.self, forKey: .quantization),
            kvCacheType: container.decode(LocalAIKVCacheType.self, forKey: .kvCacheType),
            contextTokens: container.decode(Int.self, forKey: .contextTokens),
            weightLoadingMode: container.decode(LocalAIWeightLoadingMode.self, forKey: .weightLoadingMode)
        )
    }
}

public enum LocalAIEvidenceEnvironment: String, Codable, Hashable, Sendable {
    case physicalDevice
    case simulator
    case desktopHost
}

public struct LocalAIDeviceIdentity: Codable, Hashable, Sendable {
    public let hardwareIdentifier: String
    public let chipIdentifier: String
    public let osName: String
    public let osVersion: String
    public let environment: LocalAIEvidenceEnvironment

    public init(
        hardwareIdentifier: String,
        chipIdentifier: String,
        osName: String,
        osVersion: String,
        environment: LocalAIEvidenceEnvironment
    ) throws {
        self.hardwareIdentifier = try validatedIdentifier(hardwareIdentifier, field: "hardwareIdentifier")
        self.chipIdentifier = try validatedIdentifier(chipIdentifier, field: "chipIdentifier")
        self.osName = try validatedIdentifier(osName, field: "osName")
        self.osVersion = try validatedIdentifier(osVersion, field: "osVersion")
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case hardwareIdentifier, chipIdentifier, osName, osVersion, environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            hardwareIdentifier: container.decode(String.self, forKey: .hardwareIdentifier),
            chipIdentifier: container.decode(String.self, forKey: .chipIdentifier),
            osName: container.decode(String.self, forKey: .osName),
            osVersion: container.decode(String.self, forKey: .osVersion),
            environment: container.decode(LocalAIEvidenceEnvironment.self, forKey: .environment)
        )
    }
}

public struct LocalAIExactProfile: Codable, Hashable, Sendable {
    public let model: LocalAIModelIdentity
    public let runtime: LocalAIRuntimeProfile
    public let device: LocalAIDeviceIdentity

    public init(model: LocalAIModelIdentity, runtime: LocalAIRuntimeProfile, device: LocalAIDeviceIdentity) {
        self.model = model
        self.runtime = runtime
        self.device = device
    }
}
