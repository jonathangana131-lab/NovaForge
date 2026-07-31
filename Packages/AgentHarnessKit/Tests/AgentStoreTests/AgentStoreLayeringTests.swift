import Foundation
import XCTest

final class AgentStoreLayeringTests: XCTestCase {
    func testAgentStoreSourceDoesNotImportAgentEngine() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/AgentStore", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        let sourceFiles = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }

        XCTAssertFalse(sourceFiles.isEmpty, "AgentStore source boundary must remain inspectable")

        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            for line in source.split(whereSeparator: \.isNewline) {
                let code = line.split(separator: "//", maxSplits: 1).first ?? ""
                let importsAgentEngine = code.range(
                    of: #"\bimport\s+(?:\w+\s+)?AgentEngine(?:\.|\s|$)"#,
                    options: .regularExpression
                ) != nil
                XCTAssertFalse(
                    importsAgentEngine,
                    "AgentStore must depend on AgentReducerCore, not AgentEngine: \(sourceFile.lastPathComponent)"
                )
            }
        }
    }
}
