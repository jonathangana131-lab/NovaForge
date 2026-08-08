import Foundation

extension Character {
    /// Module-local compatibility classification for control characters.
    /// Kept separate so identifier validation does not depend on a proposed
    /// Character.isControl standard-library API.
    var isControl: Bool {
        unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
