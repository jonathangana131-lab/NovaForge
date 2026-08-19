import AgentDomain
@testable import AgentProviders
import XCTest

final class ProviderRoutePathSafetyTests: XCTestCase {
    func testProfileAcceptsBoundedRelativePathThatAdapterCanDispatch() throws {
        let path = "/v1/chat/completions"
        let adapter = makeAdapter(path: path)
        let profile = try makeProfile(adapter: adapter, path: path)

        XCTAssertEqual(profile.endpoint.relativePath, path)
        XCTAssertNoThrow(try adapter.encode(request()))
    }

    func testProfileRejectsEveryPathClassExecutableAdapterRejects() {
        let oversizedPath = "/" + String(repeating: "a", count: 2_048)
        let unsafePaths = [
            "https://example.invalid/v1/chat/completions",
            "//example.invalid/v1/chat/completions",
            "v1/chat/completions",
            "/v1/chat/completions?api_key=fixture-secret",
            "/v1/chat/completions#fragment",
            "/v1\\chat\\completions",
            "/v1/chat completions",
            "/v1/chat\ncompletions",
            "/v1/\u{200D}chat/completions",
            oversizedPath,
        ]

        for path in unsafePaths {
            let adapter = makeAdapter(path: path)

            XCTAssertThrowsError(try makeProfile(adapter: adapter, path: path), path) { error in
                XCTAssertEqual(
                    error as? ProviderRouteProfileValidationError,
                    .unsafeEndpointRelativePath,
                    path
                )
            }
            XCTAssertThrowsError(try adapter.encode(request()), path) { error in
                XCTAssertEqual(
                    (error as? ProviderFailure)?.code,
                    "provider_endpoint_path_not_relative",
                    path
                )
            }
        }
    }

    func testUnsafeProfileFailureDoesNotRetainCredentialBearingPath() {
        let path = "https://user:fixture-secret@example.invalid/v1/chat/completions"
        let adapter = makeAdapter(path: path)

        XCTAssertThrowsError(try makeProfile(adapter: adapter, path: path)) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .unsafeEndpointRelativePath
            )
            XCTAssertFalse(String(reflecting: error).contains("fixture-secret"))
        }
    }

    func testDescriptorPathMismatchStillFailsBeforePathSafetyClassification() {
        let descriptorPath = "/v1/chat/completions"
        let profilePath = "https://example.invalid/v1/chat/completions"
        let adapter = makeAdapter(path: descriptorPath)

        XCTAssertThrowsError(try makeProfile(adapter: adapter, path: profilePath)) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .descriptorPathMismatch(
                    descriptorPath: descriptorPath,
                    profilePath: profilePath
                )
            )
        }
    }

    private func makeAdapter(path: String) -> OpenAICompatibleAdapter {
        OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "path-safety-fixture"),
            adapterID: .init(rawValue: "path-safety-chat"),
            modelID: .init(rawValue: "fixture-model"),
            requestPath: path
        ))
    }

    private func makeProfile(
        adapter: OpenAICompatibleAdapter,
        path: String
    ) throws -> ProviderRouteProfile {
        try ProviderRouteProfile(
            descriptor: adapter.descriptor,
            endpoint: .init(
                authorityID: "path-safety-authority",
                relativePath: path
            ),
            authenticationMode: .callerManaged,
            dataHandling: .init(
                policyID: "path-safety-policy",
                classification: .standardHosted,
                requiresPreUseDisclosure: true,
                sourceID: "path-safety-source",
                verifiedAtISO8601: "2026-08-19T00:00:00Z"
            ),
            replayPolicy: .none,
            retryBehavior: .never,
            cancellationBehavior: .unavailable,
            supportState: .supported,
            evidence: .init(
                catalogSourceID: "path-safety-catalog",
                healthSourceID: "path-safety-health",
                revision: "path-safety-r1"
            )
        )
    }

    private func request() -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: "path-safety-request",
            model: .init(rawValue: "fixture-model"),
            messages: [
                .init(role: .user, content: [.text("Hello")]),
            ]
        )
    }
}
