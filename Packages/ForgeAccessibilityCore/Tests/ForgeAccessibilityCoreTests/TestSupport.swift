import ForgeAccessibilityCore
import Foundation
import XCTest

struct ExactAuthenticator: ForgeAccessibilityEvidenceAuthenticating {
    let accepted: Set<ForgeAccessibilityObservation>
    func authenticates(_ observation: ForgeAccessibilityObservation) -> Bool {
        accepted.contains(observation)
    }
}


func id(_ raw: String) throws -> ForgeAccessibilityID {
    try ForgeAccessibilityID(rawValue: raw)
}

func finding(
    _ raw: String,
    category: ForgeAccessibilityCategory,
    severity: ForgeAccessibilityFindingSeverity
) throws -> ForgeAccessibilityFinding {
    try ForgeAccessibilityFinding(
        id: id(raw),
        category: category,
        severity: severity,
        summary: "Finding \(raw)"
    )
}

struct Fixture {
    let target: ForgeAccessibilityTarget
    let voiceOverRequirement: ForgeAccessibilityRequirement
    let dynamicTypeRequirement: ForgeAccessibilityRequirement
    let reduceMotionRequirement: ForgeAccessibilityRequirement
    let reduceTransparencyRequirement: ForgeAccessibilityRequirement
    let policy: ForgeAccessibilityAcceptancePolicy

    init() throws {
        target = ForgeAccessibilityTarget(
            projectID: try ForgeAccessibilityID(rawValue: "project-1"),
            sourceRevision: try ForgeAccessibilityID(rawValue: "rev-1"),
            journeyID: try ForgeAccessibilityID(rawValue: "journey-main")
        )
        voiceOverRequirement = ForgeAccessibilityRequirement(
            id: try ForgeAccessibilityID(rawValue: "voiceover"),
            category: .voiceOverNavigation,
            environmentProfile: .voiceOver
        )
        dynamicTypeRequirement = ForgeAccessibilityRequirement(
            id: try ForgeAccessibilityID(rawValue: "dynamic-type"),
            category: .dynamicType,
            environmentProfile: .dynamicTypeXXXL
        )
        reduceMotionRequirement = ForgeAccessibilityRequirement(
            id: try ForgeAccessibilityID(rawValue: "reduce-motion"),
            category: .reduceMotion,
            environmentProfile: .reduceMotion
        )
        reduceTransparencyRequirement = ForgeAccessibilityRequirement(
            id: try ForgeAccessibilityID(rawValue: "reduce-transparency"),
            category: .reduceTransparency,
            environmentProfile: .reduceTransparency
        )
        policy = try ForgeAccessibilityAcceptancePolicy(
            requirements: [
                voiceOverRequirement,
                dynamicTypeRequirement,
                reduceMotionRequirement,
                reduceTransparencyRequirement,
            ],
            allowedExecutionKinds: [.simulator, .physicalDevice],
            requiredDeviceIdentifier: "iPhone-sim-profile",
            requiredOSBuild: "27A-test"
        )
    }

    func policy(
        for requirements: [ForgeAccessibilityRequirement],
        blocksMedium: Bool = false,
        blocksLow: Bool = false,
        requiredDevice: String? = "iPhone-sim-profile",
        requiredBuild: String? = "27A-test"
    ) throws -> ForgeAccessibilityAcceptancePolicy {
        try ForgeAccessibilityAcceptancePolicy(
            requirements: requirements,
            allowedExecutionKinds: [.simulator],
            requiredDeviceIdentifier: requiredDevice,
            requiredOSBuild: requiredBuild,
            blocksMediumFindings: blocksMedium,
            blocksLowFindings: blocksLow
        )
    }

    func completePassingObservations() throws -> [ForgeAccessibilityObservation] {
        try policy.requirements.map { try observation(for: $0) }
    }

    func observation(
        for requirement: ForgeAccessibilityRequirement,
        environment suppliedEnvironment: ForgeAccessibilityEnvironment? = nil,
        outcome: ForgeAccessibilityObservationOutcome = .passed,
        findings: [ForgeAccessibilityFinding] = []
    ) throws -> ForgeAccessibilityObservation {
        let environment = try suppliedEnvironment ?? self.environment(profile: requirement.environmentProfile)
        return try ForgeAccessibilityObservation(
            id: ForgeAccessibilityID(rawValue: "obs-\(requirement.id.rawValue)"),
            target: target,
            requirementID: requirement.id,
            category: requirement.category,
            environment: environment,
            outcome: outcome,
            producer: .xctest,
            evidenceReceiptID: ForgeAccessibilityID(rawValue: "receipt-\(requirement.id.rawValue)"),
            findings: findings
        )
    }

    func environment(
        profile: ForgeAccessibilityEnvironmentProfile,
        deviceIdentifier: String = "iPhone-sim-profile",
        orientation: ForgeAccessibilityOrientation = .portrait,
        contentSize: ForgeAccessibilityContentSize? = nil
    ) throws -> ForgeAccessibilityEnvironment {
        let resolvedContentSize: ForgeAccessibilityContentSize
        if let contentSize {
            resolvedContentSize = contentSize
        } else if profile == .dynamicTypeXXXL || profile == .voiceOverAndDynamicTypeXXXL {
            resolvedContentSize = .extraExtraExtraLarge
        } else {
            resolvedContentSize = .large
        }
        return try ForgeAccessibilityEnvironment(
            executionKind: .simulator,
            deviceIdentifier: deviceIdentifier,
            osName: "iOS",
            osVersion: "27.0",
            osBuild: "27A-test",
            orientation: orientation,
            contentSize: resolvedContentSize,
            voiceOverEnabled: profile == .voiceOver || profile == .voiceOverAndDynamicTypeXXXL,
            reduceMotionEnabled: profile == .reduceMotion,
            reduceTransparencyEnabled: profile == .reduceTransparency,
            increasedContrastEnabled: profile == .increasedContrast
        )
    }
}
