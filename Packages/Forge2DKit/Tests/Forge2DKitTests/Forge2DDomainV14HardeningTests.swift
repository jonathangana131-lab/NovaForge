import Foundation
import Testing
@testable import Forge2DKit

private struct RawForge2DInputSnapshot: Encodable {
    let source: Forge2DInputSource
    let values: [Forge2DActionID: Double]
}

private struct RawForge2DPerformanceSample: Encodable {
    let measuredFramesPerSecond: Double?
    let visibleSprites: Int
    let physicsBodies: Int
    let particles: Int
}

@Test func vectorDecodeRejectsNonFiniteCoordinates() throws {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "INF",
        negativeInfinity: "-INF",
        nan: "NaN"
    )

    #expect(throws: DecodingError.self) {
        try decoder.decode(Forge2DVector.self, from: Data(#"{"x":"NaN","y":1}"#.utf8))
    }
}

@Test func rectangleDecodeRejectsInvertedPersistedBounds() {
    let data = Data(#"{"min":{"x":10,"y":0},"max":{"x":5,"y":20}}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Forge2DRect.self, from: data)
    }
}

@Test func collisionContactDecodeRejectsNegativePenetration() {
    let data = Data(#"{"normal":{"x":1,"y":0},"penetration":-1}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Forge2DCollisionContact.self, from: data)
    }
}

@Test func fixedStepPlanDecodeRejectsImpossiblePersistedState() {
    let data = Data(
        #"{"stepCount":17,"fixedStepDuration":0.0166666667,"interpolationAlpha":1,"discardedFrameDuration":-1}"#.utf8
    )
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Forge2DStepPlan.self, from: data)
    }
}

@Test func inputSnapshotDecodeRejectsUnnormalizedPersistedActions() throws {
    let throttle = try Forge2DActionID("throttle")
    let encoded = try JSONEncoder().encode(
        RawForge2DInputSnapshot(source: .automation, values: [throttle: 4])
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Forge2DInputSnapshot.self, from: encoded)
    }
}

@Test func performanceSampleDecodeRejectsImpossiblePersistedEvidence() throws {
    let encoded = try JSONEncoder().encode(
        RawForge2DPerformanceSample(
            measuredFramesPerSecond: 60,
            visibleSprites: -1,
            physicsBodies: 4,
            particles: 8
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Forge2DPerformanceSample.self, from: encoded)
    }
}

@Test func hardenedDomainTypesStillRoundTripValidEncodedState() throws {
    let vector = Forge2DVector(x: 2, y: 4)
    #expect(try JSONDecoder().decode(Forge2DVector.self, from: JSONEncoder().encode(vector)) == vector)

    let rect = Forge2DRect(min: .zero, max: Forge2DVector(x: 100, y: 80))
    #expect(try JSONDecoder().decode(Forge2DRect.self, from: JSONEncoder().encode(rect)) == rect)

    let contact = Forge2DCollisionContact(normal: Forge2DVector(x: -1, y: 0), penetration: 2)
    #expect(try JSONDecoder().decode(Forge2DCollisionContact.self, from: JSONEncoder().encode(contact)) == contact)

    var clock = Forge2DFixedStepClock(configuration: try Forge2DLoopConfiguration())
    let plan = clock.advance(frameDuration: 1.0 / 60.0)
    #expect(try JSONDecoder().decode(Forge2DStepPlan.self, from: JSONEncoder().encode(plan)) == plan)

    let action = try Forge2DActionID("move.x")
    let snapshot = Forge2DInputSnapshot(source: .automation, values: [action: 0.75])
    #expect(try JSONDecoder().decode(Forge2DInputSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)

    let sample = Forge2DPerformanceSample(
        measuredFramesPerSecond: 59.5,
        visibleSprites: 20,
        physicsBodies: 4,
        particles: 80
    )
    #expect(try JSONDecoder().decode(Forge2DPerformanceSample.self, from: JSONEncoder().encode(sample)) == sample)
}
