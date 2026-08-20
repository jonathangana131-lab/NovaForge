import RealityKit
import UIKit

/// The renderer uses one concrete RealityKit material type throughout.
/// Keeping this alias module-local prevents collisions with SwiftUI.Material.
typealias Material = SimpleMaterial

extension SimpleMaterial {
    /// Keeps renderer call sites readable across RealityKit SDK revisions.
    init(color: UIColor, roughness: Float, isMetallic: Bool) {
        self.init(
            color: color,
            roughness: MaterialScalarParameter.float(roughness),
            isMetallic: isMetallic
        )
    }
}
