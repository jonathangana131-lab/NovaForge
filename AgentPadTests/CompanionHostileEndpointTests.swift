import Foundation
import AgentProviders
import XCTest
@testable import NovaForge

final class CompanionHostileEndpointTests: XCTestCase {
    func testHostileEndpointInputsAreRejectedByDefault() {
        let rejected = [
            "https://example.com/v1",
            "https://user:password@192.168.1.20:8080",
            "http://10.0.0.8:8080/?access_token=secret",
            "http://10.0.0.8:8080/#secret",
            "http://127.0.0.1:8080",
            "http://localhost:8080",
            "http://[192.168.1.20:8080",
            "http://[2001:db8::1]"
        ]

        for input in rejected {
            XCTAssertNil(
                CompanionEndpointPolicy.normalizedBaseURL(from: input),
                "Hostile endpoint must be rejected: \(input)"
            )
        }

        XCTAssertNotNil(
            CompanionEndpointPolicy.normalizedBaseURL(
                from: "http://127.0.0.1:8080",
                allowLoopbackForSimulatorTesting: true
            )
        )
    }

    func testRedirectOriginPinningRejectsEveryOriginChange() throws {
        let origin = try XCTUnwrap(URL(string: "https://forge-box.local:8443"))
        let sameOriginURLs = [
            "https://forge-box.local:8443/v1/models",
            "https://FORGE-BOX.LOCAL:8443/v1/chat/completions"
        ]
        for value in sameOriginURLs {
            XCTAssertTrue(CompanionEndpointPolicy.sameOrigin(origin, try XCTUnwrap(URL(string: value))))
        }

        let redirectedAway = [
            "http://forge-box.local:8443/v1/models",
            "https://other-box.local:8443/v1/models",
            "https://forge-box.local:9443/v1/models",
            "https://forge-box.local/v1/models"
        ]
        for value in redirectedAway {
            XCTAssertFalse(CompanionEndpointPolicy.sameOrigin(origin, try XCTUnwrap(URL(string: value))))
        }
    }

    func testAttestationFailsClosedForEveryIdentityOrCapabilityMismatch() throws {
        let descriptor = try XCTUnwrap(LocalModelCatalog.all.first { $0.engineType == .companion })
        let valid = CompanionServerAttestation(
            modelID: CompanionEndpointPolicy.companionModelID,
            revision: descriptor.immutableRevision,
            runtime: "llama.cpp",
            capabilities: ["text", "streaming"],
            contextLimit: descriptor.contextTokens,
            textOnly: true,
            mtpSupported: true
        )
        XCTAssertTrue(
            CompanionEndpointPolicy.validateAttestation(
                valid,
                for: descriptor,
                expectedRevision: descriptor.immutableRevision
            )
        )

        let mismatches: [CompanionServerAttestation] = [
            .init(
                modelID: "Qwen/Qwen3.8-27B-vision",
                revision: valid.revision,
                runtime: valid.runtime,
                capabilities: valid.capabilities,
                contextLimit: valid.contextLimit,
                textOnly: valid.textOnly,
                mtpSupported: valid.mtpSupported
            ),
            .init(
                modelID: valid.modelID,
                revision: String(repeating: "a", count: 39),
                runtime: valid.runtime,
                capabilities: valid.capabilities,
                contextLimit: valid.contextLimit,
                textOnly: valid.textOnly,
                mtpSupported: valid.mtpSupported
            ),
            .init(
                modelID: valid.modelID,
                revision: valid.revision,
                runtime: "python",
                capabilities: valid.capabilities,
                contextLimit: valid.contextLimit,
                textOnly: valid.textOnly,
                mtpSupported: valid.mtpSupported
            ),
            .init(
                modelID: valid.modelID,
                revision: valid.revision,
                runtime: valid.runtime,
                capabilities: ["text"],
                contextLimit: valid.contextLimit,
                textOnly: valid.textOnly,
                mtpSupported: valid.mtpSupported
            ),
            .init(
                modelID: valid.modelID,
                revision: valid.revision,
                runtime: valid.runtime,
                capabilities: valid.capabilities,
                contextLimit: descriptor.contextTokens - 1,
                textOnly: valid.textOnly,
                mtpSupported: valid.mtpSupported
            ),
            .init(
                modelID: valid.modelID,
                revision: valid.revision,
                runtime: valid.runtime,
                capabilities: valid.capabilities,
                contextLimit: valid.contextLimit,
                textOnly: false,
                mtpSupported: valid.mtpSupported
            )
        ]

        for attestation in mismatches {
            XCTAssertFalse(
                CompanionEndpointPolicy.validateAttestation(
                    attestation,
                    for: descriptor,
                    expectedRevision: descriptor.immutableRevision
                ),
                "Attestation mismatch must fail closed: \(attestation)"
            )
        }
    }

    func testAttestationRequiresMTPMetadataOnTheWire() throws {
        let json = #"{"id":"Qwen/Qwen3.8-27B","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","runtime":"mlx","capabilities":["text","streaming"],"context_limit":4096,"text_only":true}"#
        XCTAssertThrowsError(try JSONDecoder().decode(CompanionServerAttestation.self, from: Data(json.utf8)))
    }

    func testCompanionSSEFramingRejectsMalformedAndTruncatedEvents() throws {
        var parser = CompanionInferenceEngine.SSEParser()
        XCTAssertNil(try parser.consume(#"data: {"choices":[]}"#))
        let event = try XCTUnwrap(try parser.consume(""))
        XCTAssertFalse(event.done)
        XCTAssertEqual(event.data, Data(#"{"choices":[]}"#.utf8))

        var unsupportedField = CompanionInferenceEngine.SSEParser()
        XCTAssertThrowsError(try unsupportedField.consume("event: message"))

        var mixedDone = CompanionInferenceEngine.SSEParser()
        XCTAssertNil(try mixedDone.consume("data: {\"choices\":[]}"))
        XCTAssertThrowsError(try mixedDone.consume("data: [DONE]"))

        var oversized = CompanionInferenceEngine.SSEParser()
        XCTAssertThrowsError(try oversized.consume("data: " + String(repeating: "x", count: 512 * 1_024 + 1)))
    }

    func testConsentMigrationRevocationAndIdentityChangeNeverReuseAnOldGrant() throws {
        let suite = "CompanionHostilePrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let descriptor = try XCTUnwrap(LocalModelCatalog.all.first { $0.engineType == .companion })

        // A legacy/configuration-only record is not consent. Only the new
        // identity-bound fingerprint key can authorize content transfer.
        defaults.set(true, forKey: "localAI2.companion.consent")
        try CompanionModelConfigurationStore.saveConfirmed(
            endpointText: "http://10.0.0.8:8080",
            descriptor: descriptor,
            defaults: defaults
        )
        let first = try XCTUnwrap(CompanionModelConfigurationStore.snapshot(defaults: defaults))
        XCTAssertFalse(CompanionPrivacyStore.isConsented(first, defaults: defaults))

        CompanionPrivacyStore.grant(for: first, defaults: defaults)
        XCTAssertTrue(CompanionPrivacyStore.isConsented(first, defaults: defaults))

        try CompanionModelConfigurationStore.saveConfirmed(
            endpointText: "http://10.0.0.9:8080",
            descriptor: descriptor,
            defaults: defaults
        )
        let changed = try XCTUnwrap(CompanionModelConfigurationStore.snapshot(defaults: defaults))
        XCTAssertFalse(CompanionPrivacyStore.isConsented(changed, defaults: defaults))

        CompanionPrivacyStore.grant(for: changed, defaults: defaults)
        CompanionPrivacyStore.revoke(defaults: defaults)
        XCTAssertFalse(CompanionPrivacyStore.isConsented(changed, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: CompanionPrivacyStore.consentFingerprintKey))
    }

    func testCompanionEngineRejectsContentBeforeConsentWithoutOpeningNetwork() async throws {
        let descriptor = try XCTUnwrap(LocalModelCatalog.all.first { $0.engineType == .companion })

        // The production engine currently reads the app defaults store. Save
        // and restore its narrow companion keys so this gate test cannot
        // disturb a user's configured route.
        let defaults = UserDefaults.standard
        let keys = [
            "localAI2.companion.endpoint",
            "localAI2.companion.model",
            "localAI2.companion.revision",
            "localAI2.companion.confirmedAt",
            CompanionPrivacyStore.consentFingerprintKey
        ]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = saved[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        // No configuration means the engine must fail before URLSession.
        CompanionModelConfigurationStore.revoke()
        CompanionPrivacyStore.revoke()
        let request = AgentLocalModelInferenceRequest(
            scope: ProviderAttemptScope(
                requestID: "companion-no-content",
                attemptID: .init(rawValue: "companion-no-content:attempt:1")
            ),
            modelID: descriptor.id,
            messages: [.init(role: .user, content: "PRIVATE WORKSPACE SECRET")],
            temperature: 0,
            maximumOutputTokens: 1
        )
        do {
            try await CompanionInferenceEngine().stream(request: request) { _ in }
            XCTFail("Companion must not send content without explicit consent")
        } catch let error as LocalModelRuntimeError {
            guard case .companionConsentRequired = error else {
                XCTFail("Expected consent gate, got \(error)")
                return
            }
        }
    }
}
