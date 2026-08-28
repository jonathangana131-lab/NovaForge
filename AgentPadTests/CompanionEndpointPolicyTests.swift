import Foundation
import XCTest
@testable import NovaForge

final class CompanionEndpointPolicyTests: XCTestCase {
    func testPrivateLANPolicyRejectsCredentialsQueriesPublicHostsAndLoopback() {
        XCTAssertNil(CompanionEndpointPolicy.normalizedBaseURL(from: "https://user:secret@192.168.1.20:8080"))
        XCTAssertNil(CompanionEndpointPolicy.normalizedBaseURL(from: "http://10.0.0.8:8080/?token=secret"))
        XCTAssertNil(CompanionEndpointPolicy.normalizedBaseURL(from: "http://api.example.com:8080"))
        XCTAssertNil(CompanionEndpointPolicy.normalizedBaseURL(from: "http://127.0.0.1:8080"))
        XCTAssertNotNil(CompanionEndpointPolicy.normalizedBaseURL(from: "http://127.0.0.1:8080", allowLoopbackForSimulatorTesting: true))
        XCTAssertNotNil(CompanionEndpointPolicy.normalizedBaseURL(from: "https://forge-box.local/v1/"))
    }

    func testOriginPinningRejectsSchemeHostAndPortChanges() throws {
        let origin = try XCTUnwrap(URL(string: "https://10.0.0.8:8443"))
        XCTAssertTrue(CompanionEndpointPolicy.sameOrigin(origin, URL(string: "https://10.0.0.8:8443/v1/models")!))
        XCTAssertFalse(CompanionEndpointPolicy.sameOrigin(origin, URL(string: "http://10.0.0.8:8443/v1/models")!))
        XCTAssertFalse(CompanionEndpointPolicy.sameOrigin(origin, URL(string: "https://10.0.0.9:8443/v1/models")!))
        XCTAssertFalse(CompanionEndpointPolicy.sameOrigin(origin, URL(string: "https://10.0.0.8:443/v1/models")!))
    }

    func testAttestationRequiresExactIdentityTextOnlyContextAndCompleteMetadata() throws {
        let descriptor = try XCTUnwrap(LocalModelCatalog.all.first { $0.engineType == .companion })
        let valid = CompanionServerAttestation(
            modelID: CompanionEndpointPolicy.companionModelID,
            revision: descriptor.immutableRevision,
            runtime: "mlx",
            capabilities: ["text", "streaming"],
            contextLimit: descriptor.contextTokens,
            textOnly: true,
            mtpSupported: false
        )
        XCTAssertTrue(CompanionEndpointPolicy.validateAttestation(valid, for: descriptor, expectedRevision: descriptor.immutableRevision))

        let wrongModel = CompanionServerAttestation(
            modelID: "Qwen/Qwen3.8-27B-vision",
            revision: valid.revision,
            runtime: valid.runtime,
            capabilities: valid.capabilities,
            contextLimit: valid.contextLimit,
            textOnly: valid.textOnly,
            mtpSupported: valid.mtpSupported
        )
        XCTAssertFalse(CompanionEndpointPolicy.validateAttestation(wrongModel, for: descriptor, expectedRevision: descriptor.immutableRevision))
        XCTAssertFalse(CompanionEndpointPolicy.validateAttestation(valid, for: descriptor, expectedRevision: String(repeating: "z", count: 40)))
    }

    func testConsentIsIdentityBoundAndAbsentBeforeExplicitGrant() throws {
        let suiteName = "CompanionPrivacyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let descriptor = try XCTUnwrap(
            LocalModelCatalog.all.first { $0.engineType == .companion }
        )

        try CompanionModelConfigurationStore.saveConfirmed(
            endpointText: "http://10.0.0.8:8080/",
            descriptor: descriptor,
            defaults: defaults
        )
        let first = try XCTUnwrap(
            CompanionModelConfigurationStore.snapshot(defaults: defaults)
        )
        XCTAssertFalse(CompanionPrivacyStore.isConsented(first, defaults: defaults))
        XCTAssertNotNil(
            CompanionModelConfigurationStore.compatibilityMessage(defaults: defaults)
        )

        CompanionPrivacyStore.grant(for: first, defaults: defaults)
        XCTAssertTrue(CompanionPrivacyStore.isConsented(first, defaults: defaults))
        XCTAssertNil(CompanionModelConfigurationStore.compatibilityMessage(defaults: defaults))

        try CompanionModelConfigurationStore.saveConfirmed(
            endpointText: "http://10.0.0.9:8080",
            descriptor: descriptor,
            defaults: defaults
        )
        let second = try XCTUnwrap(
            CompanionModelConfigurationStore.snapshot(defaults: defaults)
        )
        XCTAssertNotEqual(first.endpoint, second.endpoint)
        XCTAssertFalse(CompanionPrivacyStore.isConsented(second, defaults: defaults))
    }

    func testRevokeClearsConfigurationAndFingerprint() throws {
        let suiteName = "CompanionPrivacyRevokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let descriptor = try XCTUnwrap(
            LocalModelCatalog.all.first { $0.engineType == .companion }
        )
        try CompanionModelConfigurationStore.saveConfirmed(
            endpointText: "http://10.0.0.8:8080",
            descriptor: descriptor,
            defaults: defaults
        )
        let configuration = try XCTUnwrap(
            CompanionModelConfigurationStore.snapshot(defaults: defaults)
        )
        CompanionPrivacyStore.grant(for: configuration, defaults: defaults)
        XCTAssertTrue(
            defaults.object(forKey: CompanionPrivacyStore.consentFingerprintKey) != nil
        )

        CompanionModelConfigurationStore.revoke(defaults: defaults)

        XCTAssertNil(CompanionModelConfigurationStore.snapshot(defaults: defaults))
        XCTAssertFalse(CompanionPrivacyStore.isConsented(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: CompanionPrivacyStore.consentFingerprintKey))
    }
}
