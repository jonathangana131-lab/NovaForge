import Foundation
import XCTest
@testable import ForgeRepairCore

final class ForgeRepairTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotEvaluateCandidateCampaignDirectly() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "RepairCandidateEvaluationBypass.swift",
            source: """
            import ForgeRepairCore

            func bypass(_ campaign: RepairCampaign) {
                _ = campaign.assess()
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected ordinary import to reject candidate campaign evaluation, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotMintTrustedCampaignOrAssessment() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "RepairAuthorityMintBypass.swift",
            source: """
            import ForgeRepairCore

            func mint(_ campaign: RepairCampaign) {
                let trusted = ForgeRepairTrustedCampaign(authenticatedCampaign: campaign)
                _ = ForgeRepairTrustedAssessment(campaign: trusted.campaign)
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected ordinary import to reject trusted repair authority minting, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotDecodeTrustedAssessment() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "RepairAuthorityDecodeBypass.swift",
            source: """
            import Foundation
            import ForgeRepairCore

            func decode(_ data: Data) throws {
                _ = try JSONDecoder().decode(ForgeRepairTrustedAssessment.self, from: data)
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("decodable")
                || diagnostics.localizedCaseInsensitiveContains("decode"),
            "Expected trusted repair assessment to remain non-decodable, got: \(diagnostics)"
        )
    }

    func testPackageAuthorityDerivesSameCandidateProjectionAfterTrust() throws {
        let projectID = try RepairProjectID(rawValue: "project")
        let defectID = try RepairDefectID(rawValue: "defect")
        let sourceRevision = try RepairRevisionID(rawValue: "source")
        let candidateRevision = try RepairRevisionID(rawValue: "candidate")
        let checkpointID = try RepairCheckpointID(rawValue: "checkpoint")
        let receipt = try RepairReceiptID(rawValue: "receipt")
        let focused = try RepairReceiptID(rawValue: "focused")

        let defect = try RepairDefect(
            id: defectID,
            projectID: projectID,
            discoveredRevisionID: sourceRevision,
            defectClass: .runtime,
            severity: .high,
            summary: "Runtime defect",
            evidenceReceiptIDs: [receipt]
        )
        let before = try RepairEvidenceScorecard(
            targetDefectObserved: true,
            receiptIDs: [receipt]
        )
        let after = try RepairEvidenceScorecard(
            targetDefectObserved: false,
            receiptIDs: [receipt]
        )
        let attempt = try RepairAttempt(
            id: try RepairAttemptID(rawValue: "attempt-1"),
            ordinal: 1,
            projectID: projectID,
            defectID: defectID,
            sourceRevisionID: sourceRevision,
            candidateRevisionID: candidateRevision,
            knownGoodCheckpointID: checkpointID,
            before: before,
            after: after,
            verification: try RepairVerificationReceipts(focusedTest: focused)
        )
        let campaign = try RepairCampaign(
            projectID: projectID,
            defect: defect,
            knownGoodCheckpointID: checkpointID,
            policy: try RepairPolicy(
                requireFullJourney: false,
                requireVisualRegression: false,
                requireAccessibility: false,
                requirePerformance: false
            ),
            attempts: [attempt]
        )

        let candidate = campaign.assess()
        let trusted = ForgeRepairTrustedCampaign(authenticatedCampaign: campaign)
        let authoritative = ForgeRepairAuthority.assess(trusted)

        XCTAssertEqual(authoritative.assessment, candidate)
        XCTAssertEqual(authoritative.nextAction, .acceptCandidate)
        XCTAssertEqual(authoritative.candidateRevisionID, candidateRevision)
    }

    private func typecheckExternalConsumer(
        named fileName: String,
        source: String
    ) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-repair-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent(fileName)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let modulesURL = try activeModulesURL()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swiftc",
            "-typecheck",
            "-swift-version",
            "6",
            "-I",
            modulesURL.path,
            sourceURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        XCTAssertNotEqual(process.terminationStatus, 0, "External repair-authority bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgerepaircore'"),
            "Static boundary probe failed before reaching ForgeRepairCore access control: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let anchors = [
            Bundle(for: ForgeRepairTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ]

        for anchor in anchors {
            var directory = anchor
            for _ in 0..<10 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                let moduleURL = modulesURL.appendingPathComponent("ForgeRepairCore.swiftmodule")
                if FileManager.default.fileExists(atPath: moduleURL.path) {
                    return modulesURL
                }

                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }

        throw NSError(
            domain: "ForgeRepairTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeRepairCore module is missing from the active SwiftPM XCTest bundle/executable ancestry"
            ]
        )
    }
}
