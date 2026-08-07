import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeSandboxTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeRuntimeSandboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testResolvesNestedExistingRegularFileInsideSandbox() throws {
        let assets = temporaryRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let file = assets.appendingPathComponent("app.js")
        try Data("console.log('ok')".utf8).write(to: file)

        let resolved = try ForgeRuntimeSandbox.resolveExistingFile(
            relativePath: "assets/app.js",
            under: temporaryRoot
        )

        XCTAssertEqual(resolved, file.standardizedFileURL)
    }

    func testRejectsTraversalAbsoluteEncodedAndBackslashPathsBeforeFilesystemAccess() {
        for path in ["../secret.txt", "assets/../secret.txt", "/etc/passwd", "assets/%2e%2e/secret.txt", "assets\\secret.txt", "assets//app.js"] {
            XCTAssertThrowsError(
                try ForgeRuntimeSandbox.resolveExistingFile(relativePath: path, under: temporaryRoot)
            ) { error in
                XCTAssertEqual(error as? ForgeRuntimeSandboxError, .invalidRelativePath(path))
            }
        }
    }

    func testRejectsMissingResourceAndDirectoryTarget() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeSandbox.resolveExistingFile(relativePath: "missing.js", under: temporaryRoot)
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeSandboxError, .resourceNotFound("missing.js"))
        }

        let directory = temporaryRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ForgeRuntimeSandbox.resolveExistingFile(relativePath: "assets", under: temporaryRoot)
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeSandboxError, .resourceIsNotRegularFile("assets"))
        }
    }

    func testRejectsSymbolicLinkToOutsideSandbox() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeRuntimeOutside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside)

        let link = temporaryRoot.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(
            try ForgeRuntimeSandbox.resolveExistingFile(relativePath: "escape.txt", under: temporaryRoot)
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeSandboxError, .symbolicLinkNotAllowed("escape.txt"))
        }
    }

    func testRejectsIntermediateSymbolicLinkEvenWhenDestinationExists() throws {
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeRuntimeOutsideDir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideDirectory.appendingPathComponent("index.html"))

        let link = temporaryRoot.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)

        XCTAssertThrowsError(
            try ForgeRuntimeSandbox.resolveExistingFile(relativePath: "linked/index.html", under: temporaryRoot)
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeSandboxError, .symbolicLinkNotAllowed("linked/index.html"))
        }
    }

    func testRejectsNonDirectoryRoot() throws {
        let file = temporaryRoot.appendingPathComponent("not-a-directory.txt")
        try Data().write(to: file)

        XCTAssertThrowsError(
            try ForgeRuntimeSandbox.resolveExistingFile(relativePath: "index.html", under: file)
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeSandboxError, .rootIsNotDirectory)
        }
    }
}
