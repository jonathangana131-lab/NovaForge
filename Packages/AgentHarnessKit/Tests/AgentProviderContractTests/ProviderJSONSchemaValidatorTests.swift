import AgentDomain
@testable import AgentProviders
import XCTest

final class ProviderJSONSchemaValidatorTests: XCTestCase {
    func testValidNestedObjectMatchesSupportedStrictSubset() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "minLength": .number(.integer(1)),
                    "maxLength": .number(.integer(64)),
                ]),
                "count": .object([
                    "type": .string("integer"),
                    "minimum": .number(.integer(1)),
                    "maximum": .number(.integer(10)),
                ]),
                "tags": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "maxItems": .number(.integer(3)),
                ]),
            ]),
            "required": .array([.string("path"), .string("count")]),
            "additionalProperties": .bool(false),
        ])
        let value: JSONValue = .object([
            "path": .string("Notes/today.md"),
            "count": .number(.integer(2)),
            "tags": .array([.string("one"), .string("two")]),
        ])

        XCTAssertNoThrow(try ProviderJSONSchemaValidator.validateSchema(schema))
        XCTAssertNoThrow(try ProviderJSONSchemaValidator.validate(value, against: schema))
    }

    func testMissingRequiredUnknownFieldAndWrongTypeFail() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .bool(false),
        ])

        let invalidValues: [JSONValue] = [
            .object([:]),
            .object(["path": .string("a"), "extra": .bool(true)]),
            .object(["path": .number(.integer(7))]),
        ]
        for value in invalidValues {
            assertMismatch(value, schema: schema)
        }
    }

    func testAnyOfEnumAndNumericBoundsAreEnforced() throws {
        let schema: JSONValue = .object([
            "anyOf": .array([
                .object([
                    "type": .string("string"),
                    "enum": .array([.string("auto"), .string("manual")]),
                ]),
                .object([
                    "type": .string("integer"),
                    "minimum": .number(.integer(1)),
                    "maximum": .number(.integer(3)),
                ]),
            ]),
        ])

        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(.string("auto"), against: schema)
        )
        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(.number(.integer(2)), against: schema)
        )
        assertMismatch(.string("other"), schema: schema)
        assertMismatch(.number(.integer(4)), schema: schema)
    }

    func testSchemaPreflightRejectsMalformedDormantSubschemas() {
        let malformed: JSONValue = .object([
            "type": .string("string"),
            "pattern": .string("(a+)+$"),
        ])
        let cases: [(schema: JSONValue, instance: JSONValue)] = [
            (
                .object([
                    "type": .string("object"),
                    "properties": .object(["absent": malformed]),
                ]),
                .object([:])
            ),
            (
                .object([
                    "type": .string("array"),
                    "items": malformed,
                ]),
                .array([])
            ),
            (
                .object([
                    "type": .string("object"),
                    "additionalProperties": malformed,
                ]),
                .object([:])
            ),
            (
                .object([
                    "anyOf": .array([
                        .object(["const": .string("selected")]),
                        malformed,
                    ]),
                ]),
                .string("selected")
            ),
        ]

        for value in cases {
            assertSchemaError(.invalidSchema, schema: value.schema)
            XCTAssertThrowsError(
                try ProviderJSONSchemaValidator.validate(
                    value.instance,
                    against: value.schema
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProviderJSONSchemaValidationError,
                    .invalidSchema
                )
            }
        }
    }

    func testSchemaPreflightRejectsMalformedKeywordsTypesAndBounds() {
        let invalidSchemas: [JSONValue] = [
            .object(["pattern": .string(".*")]),
            .object(["type": .string("dictionary")]),
            .object(["type": .array([])]),
            .object(["type": .array([.string("string"), .string("string")])]),
            .object(["enum": .array([])]),
            .object([
                "enum": .array([
                    .number(.integer(1)),
                    .number(.unsignedInteger(1)),
                ]),
            ]),
            .object(["allOf": .array([])]),
            .object(["properties": .array([])]),
            .object(["items": .string("not-a-schema")]),
            .object(["additionalProperties": .number(.integer(1))]),
            .object(["required": .array([.string("id"), .string("id")])]),
            .object(["required": .array([.number(.integer(1))])]),
            .object(["uniqueItems": .string("true")]),
            .object(["minItems": .number(.integer(-1))]),
            .object(["maxLength": .number(.floatingPoint(1.5))]),
            .object([
                "minProperties": .number(.integer(2)),
                "maxProperties": .number(.integer(1)),
            ]),
            .object(["minimum": .string("zero")]),
            .object([
                "minimum": .number(.floatingPoint(18_446_744_073_709_551_616.0)),
                "maximum": .number(.unsignedInteger(UInt64.max)),
            ]),
            .object(["minimum": .number(.floatingPoint(.nan))]),
            .object(["description": .number(.integer(1))]),
            .object(["examples": .string("example")]),
            .object(["default": .array([.number(.floatingPoint(.infinity))])]),
        ]

        for schema in invalidSchemas {
            assertSchemaError(.invalidSchema, schema: schema)
        }
    }

    func testConstAndEnumUseExactCrossRepresentationNumericEquality() throws {
        let one: JSONValue = .object([
            "const": .number(.integer(1)),
        ])
        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(
                .number(.unsignedInteger(1)),
                against: one
            )
        )
        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(
                .number(.floatingPoint(1.0)),
                against: one
            )
        )

        let negativeOne: JSONValue = .object([
            "enum": .array([.number(.integer(-1))]),
        ])
        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(
                .number(.floatingPoint(-1.0)),
                against: negativeOne
            )
        )

        let maximumUInt: JSONValue = .object([
            "const": .number(.unsignedInteger(UInt64.max)),
        ])
        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(
                .number(.unsignedInteger(UInt64.max)),
                against: maximumUInt
            )
        )
        // Double(UInt64.max) rounds to 2^64 and must not compare equal to max.
        assertMismatch(
            .number(.floatingPoint(Double(UInt64.max))),
            schema: maximumUInt
        )
    }

    func testUniqueItemsUsesRecursiveCrossRepresentationNumericEquality() throws {
        let schema: JSONValue = .object([
            "type": .string("array"),
            "uniqueItems": .bool(true),
        ])

        assertMismatch(
            .array([
                .number(.integer(1)),
                .number(.unsignedInteger(1)),
                .number(.floatingPoint(1.0)),
            ]),
            schema: schema
        )
        assertMismatch(
            .array([
                .object(["count": .number(.integer(1))]),
                .object(["count": .number(.unsignedInteger(1))]),
            ]),
            schema: schema
        )

        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(
                .array([
                    .number(.unsignedInteger(UInt64.max)),
                    .number(.floatingPoint(Double(UInt64.max))),
                ]),
                against: schema
            )
        )
    }

    func testNumericOrderingPreservesUInt64AndInt64Boundaries() throws {
        let maximumUInt: JSONValue = .object([
            "type": .string("number"),
            "maximum": .number(.unsignedInteger(UInt64.max)),
        ])
        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(
                .number(.unsignedInteger(UInt64.max)),
                against: maximumUInt
            )
        )
        assertMismatch(
            .number(.floatingPoint(Double(UInt64.max))),
            schema: maximumUInt
        )

        let twoToThe64: JSONValue = .object([
            "type": .string("number"),
            "minimum": .number(.floatingPoint(Double(UInt64.max))),
        ])
        assertMismatch(
            .number(.unsignedInteger(UInt64.max)),
            schema: twoToThe64
        )
        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(
                .number(.floatingPoint(Double(UInt64.max))),
                against: twoToThe64
            )
        )

        let minimumInt: JSONValue = .object([
            "type": .string("number"),
            "const": .number(.integer(Int64.min)),
        ])
        XCTAssertNoThrow(
            try ProviderJSONSchemaValidator.validate(
                .number(.floatingPoint(Double(Int64.min))),
                against: minimumInt
            )
        )
    }

    func testSchemaDepthLimitAppliesBeforeInstanceMatching() throws {
        var atLimit: JSONValue = .bool(true)
        for _ in 0..<64 {
            atLimit = .object(["items": atLimit])
        }
        XCTAssertNoThrow(try ProviderJSONSchemaValidator.validateSchema(atLimit))

        let tooDeep: JSONValue = .object(["items": atLimit])
        assertSchemaError(.limitExceeded, schema: tooDeep)

        var deepDefault: JSONValue = .null
        for _ in 0..<65 {
            deepDefault = .array([deepDefault])
        }
        assertSchemaError(
            .limitExceeded,
            schema: .object(["default": deepDefault])
        )
    }

    func testSchemaNodeLimitIncludesAnnotationLiteralTrees() {
        let oversizedExamples = Array(
            repeating: JSONValue.null,
            count: 100_000
        )
        let schema: JSONValue = .object([
            "examples": .array(oversizedExamples),
        ])

        assertSchemaError(.limitExceeded, schema: schema)
    }

    func testSemanticMatchingWorkCannotMultiplyAcrossCombinatorBranches() {
        // Both the schema and instance are individually far below the 100k-node
        // structural limit. Without shared semantic-key work accounting, each
        // failed branch rebuilt the 513-node instance key and multiplied this
        // request into more than 250k recursive visits.
        let instance: JSONValue = .array((0 ..< 512).map { index in
            .number(.integer(Int64(index)))
        })
        let branches: [JSONValue] = (0 ..< 512).map { index in
            .object([
                "const": .string("cannot-match-array-\(index)"),
            ])
        }
        let schema: JSONValue = .object([
            "anyOf": .array(branches),
        ])

        XCTAssertThrowsError(
            try ProviderJSONSchemaValidator.validate(instance, against: schema)
        ) { error in
            XCTAssertEqual(
                error as? ProviderJSONSchemaValidationError,
                .limitExceeded
            )
        }
    }

    func testNonfiniteProviderValueFailsAsMismatch() {
        assertMismatch(
            .object([
                "nested": .array([.number(.floatingPoint(.nan))]),
            ]),
            schema: .bool(true)
        )
    }

    private func assertMismatch(
        _ value: JSONValue,
        schema: JSONValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ProviderJSONSchemaValidator.validate(value, against: schema),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ProviderJSONSchemaValidationError,
                .mismatch,
                file: file,
                line: line
            )
        }
    }

    private func assertSchemaError(
        _ expected: ProviderJSONSchemaValidationError,
        schema: JSONValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ProviderJSONSchemaValidator.validateSchema(schema),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ProviderJSONSchemaValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
