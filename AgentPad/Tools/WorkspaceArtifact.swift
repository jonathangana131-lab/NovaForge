import Foundation

enum WorkspaceArtifactType: String, Codable, CaseIterable, Sendable {
    case html
    case swiftGame
    case gameSpec
    case assetPack
    case xcodeProject
    case exportBundle
    case source
    case document
    case other

    var displayName: String {
        switch self {
        case .html: "HTML"
        case .swiftGame: "Swift Game"
        case .gameSpec: "Game Spec"
        case .assetPack: "Asset Pack"
        case .xcodeProject: "Xcode Project"
        case .exportBundle: "Export Bundle"
        case .source: "Source"
        case .document: "Document"
        case .other: "Artifact"
        }
    }

    var symbolName: String {
        switch self {
        case .html: "play.rectangle.fill"
        case .swiftGame: "gamecontroller.fill"
        case .gameSpec: "list.bullet.rectangle.fill"
        case .assetPack: "photo.stack.fill"
        case .xcodeProject: "hammer.fill"
        case .exportBundle: "shippingbox.fill"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .document: "doc.text.fill"
        case .other: "doc.text.magnifyingglass"
        }
    }
}

enum ArtifactPreviewMode: String, Codable, CaseIterable, Sendable {
    case web
    case nativeGame
    case source
    case files
}

enum ArtifactOrientationPreference: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
    case adaptive
}

enum WorkspaceArtifactStatus: String, Codable, CaseIterable, Sendable {
    case generated
    case playable
    case exported
    case failed
}

struct WorkspaceArtifact: Identifiable, Hashable, Sendable {
    let path: String

    var id: String { path }

    var title: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var fileExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    var isWebPage: Bool {
        ["html", "htm", "svg"].contains(fileExtension)
    }

    var isImageArtifact: Bool {
        ["png", "jpg", "jpeg", "webp", "gif"].contains(fileExtension)
    }

    var isPDFArtifact: Bool {
        fileExtension == "pdf"
    }

    var isMarkdownArtifact: Bool {
        ["md", "markdown"].contains(fileExtension)
    }

    var isLogArtifact: Bool {
        let lower = path.lowercased()
        return fileExtension == "log" || lower.hasPrefix("logs/") || lower.contains("/logs/")
    }

    var isReportArtifact: Bool {
        let lower = path.lowercased()
        return lower.contains("report") || lower.contains("proof") || lower.contains("verification") || lower.contains("qa/")
    }

    var isReadablePreviewArtifact: Bool {
        isWebPage || isSwiftGameArtifact || isImageArtifact || isPDFArtifact || [
            "md", "markdown", "txt", "log", "json", "csv", "yaml", "yml", "xml", "plist", "swift", "js", "css", "py", "sh"
        ].contains(fileExtension)
    }

    var isSwiftGameArtifact: Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".nf-game.json") || lower.hasSuffix(".swift-game.json")
    }

    var artifactType: WorkspaceArtifactType {
        if isSwiftGameArtifact { return .swiftGame }
        if ["html", "htm", "svg"].contains(fileExtension) { return .html }
        if fileExtension == "xcodeproj" { return .xcodeProject }
        if path.lowercased().hasSuffix(".export.json") { return .exportBundle }
        if fileExtension == "json" && path.lowercased().contains("game") { return .gameSpec }
        if ["png", "jpg", "jpeg", "webp", "gif"].contains(fileExtension) { return .assetPack }
        if ["swift", "js", "css", "py", "sh"].contains(fileExtension) { return .source }
        if ["md", "markdown", "txt", "csv", "log", "pdf", "yaml", "yml", "xml", "plist"].contains(fileExtension) { return .document }
        return .other
    }

    var previewMode: ArtifactPreviewMode {
        switch artifactType {
        case .html:
            return .web
        case .swiftGame:
            return .nativeGame
        case .assetPack, .xcodeProject, .exportBundle:
            return .files
        case .gameSpec, .source, .document, .other:
            return .source
        }
    }

    var orientationPreference: ArtifactOrientationPreference {
        isSwiftGameArtifact || isPlayableWebArtifact ? .landscape : .adaptive
    }

    var isPlayableWebArtifact: Bool {
        guard ["html", "htm"].contains(fileExtension) else { return false }
        let tokens = path
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let playableTokens: Set<String> = [
            "game", "games", "play", "playable", "arcade", "snake", "slither",
            "pong", "breakout", "tetris", "runner", "maze", "racer", "platformer"
        ]
        return tokens.contains { playableTokens.contains($0) }
    }

    var handoffTitle: String {
        if isSwiftGameArtifact { return "Ready to play" }
        if isPlayableWebArtifact { return "Ready to play" }
        if isWebPage { return "Ready to open" }
        return "Ready to open"
    }

    var handoffSymbol: String {
        if isSwiftGameArtifact { return WorkspaceArtifactType.swiftGame.symbolName }
        if isPlayableWebArtifact { return "play.rectangle.fill" }
        if isWebPage { return "safari.fill" }
        return symbol
    }

    var symbol: String {
        if isSwiftGameArtifact {
            return WorkspaceArtifactType.swiftGame.symbolName
        }
        if ["html", "htm"].contains(fileExtension) {
            return "play.rectangle"
        }
        if fileExtension == "svg" {
            return "scribble.variable"
        }
        if isImageArtifact {
            return path.lowercased().contains("screenshot") ? "camera.viewfinder" : "photo.fill"
        }
        if isPDFArtifact {
            return "doc.richtext.fill"
        }
        if isMarkdownArtifact {
            return "doc.plaintext.fill"
        }
        if isLogArtifact {
            return "terminal.fill"
        }
        if fileExtension == "json" {
            return "list.bullet.rectangle.fill"
        }
        if fileExtension == "swift" {
            return "swift"
        }
        return "doc.text.magnifyingglass"
    }

    static func fromToolOutput(_ output: String) -> WorkspaceArtifact? {
        // Tool outputs can be very large (logs, grep results, generated files). Do
        // not split the whole string just to discover a leading "Wrote path" line;
        // scan a bounded prefix line-by-line so old tool-heavy histories stay cheap
        // to snapshot and scroll.
        let maxScanCharacters = 64_000
        let maxScanLines = 140
        let scannedOutput = output.count > maxScanCharacters
            ? String(output.prefix(maxScanCharacters))
            : output

        var scannedLines = 0
        var found: WorkspaceArtifact?
        scannedOutput.enumerateLines { line, stop in
            scannedLines += 1
            if let artifact = fromToolOutputLine(line) {
                found = artifact
                stop = true
                return
            }
            if scannedLines >= maxScanLines {
                stop = true
            }
        }
        return found
    }

    private static func fromToolOutputLine(_ line: String) -> WorkspaceArtifact? {
        let firstLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstLine.isEmpty else { return nil }
        let path: String?

        if firstLine.hasPrefix("Wrote ") {
            path = String(firstLine.dropFirst("Wrote ".count))
        } else if firstLine.hasPrefix("Appended ") {
            path = String(firstLine.dropFirst("Appended ".count))
        } else if firstLine.hasPrefix("Created folder ") {
            path = nil
        } else if firstLine.hasPrefix("Created ") {
            path = String(firstLine.dropFirst("Created ".count))
        } else if firstLine.hasPrefix("Copied "), let range = firstLine.range(of: " to ") {
            path = String(firstLine[range.upperBound...])
        } else if firstLine.hasPrefix("Moved "), let range = firstLine.range(of: " to ") {
            path = String(firstLine[range.upperBound...])
        } else {
            path = nil
        }

        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        guard isSafeRelativeArtifactPath(path) else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ["html", "htm", "svg", "css", "js", "json", "md", "markdown", "txt", "log", "swift", "py", "sh", "csv", "yaml", "yml", "xml", "plist", "png", "jpg", "jpeg", "webp", "gif", "pdf", "xcodeproj"].contains(ext) else { return nil }
        return WorkspaceArtifact(path: path)
    }

    private static func isSafeRelativeArtifactPath(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        return !path
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == ".." })
    }
}

struct SwiftGameManifest: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var type: WorkspaceArtifactType
    var id: String
    var title: String
    var description: String
    var gameType: String
    var world: SwiftGameWorld
    var preferredOrientation: ArtifactOrientationPreference
    var aspectRatio: Double
    var scenes: [SwiftGameScene]
    var player: SwiftGameEntity
    var collectibles: [SwiftGameEntity]
    var enemies: [SwiftGameEntity]
    var obstacles: [SwiftGameEntity]
    var controls: SwiftGameControls
    var scoring: SwiftGameScoring
    var winCondition: SwiftGameEndCondition
    var lossCondition: SwiftGameEndCondition
    var assets: [SwiftGameAsset]
    var exportedFiles: [SwiftGameExportedFile]
    var createdAt: String
    var updatedAt: String
    var warnings: [String]

    var resolvedAspectRatio: Double {
        aspectRatio > 0 ? aspectRatio : max(0.1, world.size.width / max(1, world.size.height))
    }
}

struct SwiftGameWorld: Codable, Hashable, Sendable {
    var size: SwiftGameSize
    var backgroundColor: String
    var boundsMode: SwiftGameBoundsMode
}

enum SwiftGameBoundsMode: String, Codable, CaseIterable, Sendable {
    case clamp
    case wrap
}

struct SwiftGameScene: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var objective: String
}

enum SwiftGameEntityKind: String, Codable, CaseIterable, Sendable {
    case player
    case collectible
    case enemy
    case obstacle
    case target
}

enum SwiftGameShape: String, Codable, CaseIterable, Sendable {
    case circle
    case roundedRect
    case capsule
    case diamond
}

struct SwiftGameEntity: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: SwiftGameEntityKind
    var shape: SwiftGameShape
    var position: SwiftGamePoint
    var size: SwiftGameSize
    var color: String
    var strokeColor: String?
    var speed: Double
    var movement: SwiftGameMovement?
    var points: Int
    var damage: Int
}

struct SwiftGameMovement: Codable, Hashable, Sendable {
    var axis: SwiftGameMovementAxis
    var amplitude: Double
    var speed: Double
    var phase: Double
}

enum SwiftGameMovementAxis: String, Codable, CaseIterable, Sendable {
    case horizontal
    case vertical
}

struct SwiftGamePoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

struct SwiftGameSize: Codable, Hashable, Sendable {
    var width: Double
    var height: Double
}

struct SwiftGameControls: Codable, Hashable, Sendable {
    var movement: String
    var action: String
    var leftZone: String
    var rightZone: String
}

struct SwiftGameScoring: Codable, Hashable, Sendable {
    var scorePerCollectible: Int
    var targetScore: Int
    var startingLives: Int
}

struct SwiftGameEndCondition: Codable, Hashable, Sendable {
    var type: String
    var message: String
}

struct SwiftGameAsset: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var path: String
    var role: String
}

struct SwiftGameExportedFile: Codable, Hashable, Identifiable, Sendable {
    var id: String { path }
    var path: String
    var role: String
    var language: String
}

enum SwiftGameArtifactFactory {
    static let sampleManifestPath = "NativeSwiftGames/StarfieldSprint.nf-game.json"
    static let sampleSourcePath = "NativeSwiftGames/Exports/StarfieldSprintGame.swift"
    static let sampleReadmePath = "NativeSwiftGames/Exports/README.md"

    static func sampleManifest(now: String = "2026-07-01T00:00:00Z") -> SwiftGameManifest {
        SwiftGameManifest(
            schemaVersion: 1,
            type: .swiftGame,
            id: "starfield-sprint",
            title: "Starfield Sprint",
            description: "A native SwiftUI arcade artifact. Collect six energy cores, avoid drifting mines, and reach the gate.",
            gameType: "arcade-collect",
            world: SwiftGameWorld(
                size: SwiftGameSize(width: 960, height: 540),
                backgroundColor: "#071018",
                boundsMode: .clamp
            ),
            preferredOrientation: .landscape,
            aspectRatio: 16.0 / 9.0,
            scenes: [
                SwiftGameScene(id: "main", title: "Sprint Field", objective: "Collect all energy cores before the mines drain your shields.")
            ],
            player: SwiftGameEntity(
                id: "player",
                name: "Comet Runner",
                kind: .player,
                shape: .circle,
                position: SwiftGamePoint(x: 120, y: 270),
                size: SwiftGameSize(width: 46, height: 46),
                color: "#8AFFC1",
                strokeColor: "#F5FFF9",
                speed: 34,
                movement: nil,
                points: 0,
                damage: 0
            ),
            collectibles: [
                SwiftGameEntity(id: "core-1", name: "Energy Core", kind: .collectible, shape: .diamond, position: SwiftGamePoint(x: 250, y: 120), size: SwiftGameSize(width: 28, height: 28), color: "#FFE86B", strokeColor: nil, speed: 0, movement: nil, points: 10, damage: 0),
                SwiftGameEntity(id: "core-2", name: "Energy Core", kind: .collectible, shape: .diamond, position: SwiftGamePoint(x: 420, y: 420), size: SwiftGameSize(width: 28, height: 28), color: "#FFE86B", strokeColor: nil, speed: 0, movement: nil, points: 10, damage: 0),
                SwiftGameEntity(id: "core-3", name: "Energy Core", kind: .collectible, shape: .diamond, position: SwiftGamePoint(x: 560, y: 210), size: SwiftGameSize(width: 28, height: 28), color: "#FFE86B", strokeColor: nil, speed: 0, movement: nil, points: 10, damage: 0),
                SwiftGameEntity(id: "core-4", name: "Energy Core", kind: .collectible, shape: .diamond, position: SwiftGamePoint(x: 720, y: 390), size: SwiftGameSize(width: 28, height: 28), color: "#FFE86B", strokeColor: nil, speed: 0, movement: nil, points: 10, damage: 0),
                SwiftGameEntity(id: "core-5", name: "Energy Core", kind: .collectible, shape: .diamond, position: SwiftGamePoint(x: 810, y: 135), size: SwiftGameSize(width: 28, height: 28), color: "#FFE86B", strokeColor: nil, speed: 0, movement: nil, points: 10, damage: 0),
                SwiftGameEntity(id: "core-6", name: "Energy Core", kind: .collectible, shape: .diamond, position: SwiftGamePoint(x: 885, y: 300), size: SwiftGameSize(width: 28, height: 28), color: "#FFE86B", strokeColor: nil, speed: 0, movement: nil, points: 10, damage: 0)
            ],
            enemies: [
                SwiftGameEntity(id: "mine-1", name: "Drifting Mine", kind: .enemy, shape: .circle, position: SwiftGamePoint(x: 350, y: 270), size: SwiftGameSize(width: 54, height: 54), color: "#FF5F87", strokeColor: "#FFD5DF", speed: 0, movement: SwiftGameMovement(axis: .vertical, amplitude: 125, speed: 1.0, phase: 0.1), points: 0, damage: 1),
                SwiftGameEntity(id: "mine-2", name: "Drifting Mine", kind: .enemy, shape: .circle, position: SwiftGamePoint(x: 650, y: 265), size: SwiftGameSize(width: 54, height: 54), color: "#FF7A3D", strokeColor: "#FFE0CF", speed: 0, movement: SwiftGameMovement(axis: .horizontal, amplitude: 90, speed: 1.3, phase: 1.7), points: 0, damage: 1)
            ],
            obstacles: [
                SwiftGameEntity(id: "reef-1", name: "Gravity Reef", kind: .obstacle, shape: .roundedRect, position: SwiftGamePoint(x: 500, y: 82), size: SwiftGameSize(width: 190, height: 34), color: "#225169", strokeColor: "#6EE7FF", speed: 0, movement: nil, points: 0, damage: 0),
                SwiftGameEntity(id: "reef-2", name: "Gravity Reef", kind: .obstacle, shape: .roundedRect, position: SwiftGamePoint(x: 220, y: 455), size: SwiftGameSize(width: 175, height: 34), color: "#225169", strokeColor: "#6EE7FF", speed: 0, movement: nil, points: 0, damage: 0)
            ],
            controls: SwiftGameControls(
                movement: "drag-or-dpad",
                action: "dash",
                leftZone: "movement",
                rightZone: "dash-restart-pause"
            ),
            scoring: SwiftGameScoring(scorePerCollectible: 10, targetScore: 60, startingLives: 3),
            winCondition: SwiftGameEndCondition(type: "collectAll", message: "Gate open. Run complete."),
            lossCondition: SwiftGameEndCondition(type: "livesZero", message: "Shields down. Restart the sprint."),
            assets: [],
            exportedFiles: [
                SwiftGameExportedFile(path: sampleSourcePath, role: "playable SwiftUI source", language: "swift"),
                SwiftGameExportedFile(path: sampleReadmePath, role: "export notes", language: "markdown")
            ],
            createdAt: now,
            updatedAt: now,
            warnings: []
        )
    }

    static func sampleManifestJSON() -> String {
        encode(sampleManifest())
    }

    static func exportSource(for manifest: SwiftGameManifest = sampleManifest()) -> String {
        let title = swiftEscaped(manifest.title)
        return """
        import SwiftUI

        struct \(swiftIdentifier(manifest.title))Game: View {
            @State private var score = 0
            @State private var player = CGPoint(x: 120, y: 270)

            var body: some View {
                GeometryReader { proxy in
                    ZStack {
                        Color(red: 0.027, green: 0.063, blue: 0.094).ignoresSafeArea()
                        Canvas { context, size in
                            let scale = min(size.width / 960, size.height / 540)
                            let offset = CGPoint(x: (size.width - 960 * scale) / 2, y: (size.height - 540 * scale) / 2)
                            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                                CGRect(x: offset.x + x * scale, y: offset.y + y * scale, width: w * scale, height: h * scale)
                            }
                            context.fill(Path(roundedRect: rect(0, 0, 960, 540), cornerRadius: 28 * scale), with: .color(.black.opacity(0.22)))
                            context.fill(Path(ellipseIn: rect(player.x - 23, player.y - 23, 46, 46)), with: .color(.green))
                        }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let frame = proxy.size
                            player = CGPoint(x: min(936, max(24, value.location.x / max(1, frame.width) * 960)),
                                             y: min(516, max(24, value.location.y / max(1, frame.height) * 540)))
                            score = max(score, Int(player.x / 16))
                        })
                        VStack {
                            HStack {
                                Text("\(title)")
                                    .font(.headline.weight(.black))
                                Spacer()
                                Text("Score \\(score)")
                                    .font(.headline.monospacedDigit().weight(.black))
                            }
                            .foregroundStyle(.white)
                            .padding()
                            Spacer()
                        }
                    }
                }
            }
        }

        #Preview {
            \(swiftIdentifier(manifest.title))Game()
        }
        """
    }

    static func readme(for manifest: SwiftGameManifest = sampleManifest()) -> String {
        """
        # \(manifest.title)

        \(manifest.description)

        This export bundle was generated from `\(sampleManifestPath)`. The in-app artifact uses the same manifest contract for native playable preview, while `\(sampleSourcePath)` is a compact SwiftUI starting point for an external project.
        """
    }

    private static func encode(_ manifest: SwiftGameManifest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manifest),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func swiftEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func swiftIdentifier(_ value: String) -> String {
        let pieces = value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let joined = pieces
            .map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }
            .joined()
        return joined.isEmpty ? "NovaForge" : joined
    }
}
