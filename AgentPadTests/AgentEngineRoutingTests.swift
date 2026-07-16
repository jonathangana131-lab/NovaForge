import XCTest

final class AgentEngineRoutingTests: XCTestCase {
    func testV1IsTheFailClosedDefaultAndIndividualFlagsCannotActivateV2() throws {
        let suiteName = "NovaForgeRouting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AgentEngineRoutingPolicy.requestedRoute(defaults: defaults), .v1)

        defaults.set(
            true,
            forKey: AgentEngineRoutingPolicy.storageKey(for: .v2HostedText)
        )
        XCTAssertEqual(AgentEngineRoutingPolicy.requestedRoute(defaults: defaults), .v1)
    }

    func testExactHostedTextCanaryGateReturnsCanonicalImmutableV2FeatureSnapshot() throws {
        let suiteName = "NovaForgeRouting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AgentEngineRoutingPolicy.masterV2Key)
        defaults.set(true, forKey: AgentEngineRoutingPolicy.storageKey(for: .v2HostedText))
        defaults.set(true, forKey: AgentEngineRoutingPolicy.storageKey(for: .v2DarkReplay))

        let route = AgentEngineRoutingPolicy.requestedRoute(
            defaults: defaults,
            executionNode: .onDevice
        )
        XCTAssertEqual(route.engineVersion, .v2)
        XCTAssertEqual(route.enabledFeatures, [.v2DarkReplay, .v2HostedText])
        XCTAssertEqual(route.executionNode, .onDevice)
        XCTAssertTrue(route.shadowMode)

        defaults.set(false, forKey: AgentEngineRoutingPolicy.masterV2Key)
        XCTAssertEqual(route.engineVersion, .v2, "An accepted route is an immutable value snapshot.")
        XCTAssertEqual(AgentEngineRoutingPolicy.requestedRoute(defaults: defaults), .v1)
    }

    func testExactReadToolsCanaryGateNoLongerForcesV1() throws {
        let suiteName = "NovaForgeRouting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AgentEngineRoutingPolicy.masterV2Key)
        for feature in [
            AgentHarnessFeature.v2DarkReplay,
            .v2HostedText,
            .v2ReadTools,
        ] {
            defaults.set(
                true,
                forKey: AgentEngineRoutingPolicy.storageKey(for: feature)
            )
        }

        XCTAssertEqual(
            AgentEngineRoutingPolicy.requestedRoute(defaults: defaults),
            AgentRunRoutingMetadata(
                engineVersion: .v2,
                enabledFeatures: [
                    .v2DarkReplay,
                    .v2HostedText,
                    .v2ReadTools,
                ],
                executionNode: .onDevice,
                shadowMode: true
            )
        )
    }

    func testCanariesFailClosedForMissingWiderOrWorkerFeatures() throws {
        let suiteName = "NovaForgeRouting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AgentEngineRoutingPolicy.masterV2Key)
        defaults.set(true, forKey: AgentEngineRoutingPolicy.storageKey(for: .v2HostedText))
        XCTAssertEqual(AgentEngineRoutingPolicy.requestedRoute(defaults: defaults), .v1)

        defaults.set(true, forKey: AgentEngineRoutingPolicy.storageKey(for: .v2DarkReplay))
        defaults.set(true, forKey: AgentEngineRoutingPolicy.storageKey(for: .v2ReadTools))
        XCTAssertNotEqual(AgentEngineRoutingPolicy.requestedRoute(defaults: defaults), .v1)

        defaults.set(
            true,
            forKey: AgentEngineRoutingPolicy.storageKey(for: .v2MutationTools)
        )
        XCTAssertEqual(AgentEngineRoutingPolicy.requestedRoute(defaults: defaults), .v1)
        defaults.set(false, forKey: AgentEngineRoutingPolicy.storageKey(for: .v2MutationTools))
        XCTAssertEqual(
            AgentEngineRoutingPolicy.requestedRoute(
                defaults: defaults,
                executionNode: .pairedWorker
            ),
            .v1
        )
    }

    func testRoutingMetadataRoundTripsDeterministicallyAndCanonicalizesFeatures() throws {
        let route = AgentRunRoutingMetadata(
            engineVersion: .v2,
            enabledFeatures: [.v2Worker, .v2DarkReplay, .v2Worker],
            executionNode: .pairedWorker,
            shadowMode: true
        )
        XCTAssertEqual(route.enabledFeatures, [.v2DarkReplay, .v2Worker])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(route)
        XCTAssertEqual(try JSONDecoder().decode(AgentRunRoutingMetadata.self, from: encoded), route)
        XCTAssertEqual(try encoder.encode(route), encoded)
    }

    func testEveryV1RunInfersV1RoutingWithoutChangingSchemaShape() {
        let run = AgentRunRecord(status: .running)
        XCTAssertEqual(run.acceptedRoutingMetadata, .v1)
    }
}
