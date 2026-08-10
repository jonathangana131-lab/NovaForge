import Foundation

extension Forge2DBlueprint {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V14CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let slug = try container.decode(String.self, forKey: .slug)
        let orientation = try container.decode(Forge2DOrientation.self, forKey: .orientation)
        let viewportWidth = try container.decode(Int.self, forKey: .viewportWidth)
        let viewportHeight = try container.decode(Int.self, forKey: .viewportHeight)
        let worldWidth = try container.decode(Int.self, forKey: .worldWidth)
        let worldHeight = try container.decode(Int.self, forKey: .worldHeight)
        let gravity = try container.decode(Double.self, forKey: .gravity)
        let persistenceKey = try container.decodeIfPresent(String.self, forKey: .persistenceKey)

        self.init(
            name: name,
            slug: slug,
            orientation: orientation,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            worldWidth: worldWidth,
            worldHeight: worldHeight,
            gravity: gravity,
            persistenceKey: persistenceKey
        )

        do {
            try Forge2DBlueprintValidator.validate(self)
        } catch let issue as Forge2DBlueprintIssue {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Forge2D blueprint: \(issue.description)",
                    underlyingError: issue
                )
            )
        }
    }

    private enum V14CodingKeys: String, CodingKey {
        case name
        case slug
        case orientation
        case viewportWidth
        case viewportHeight
        case worldWidth
        case worldHeight
        case gravity
        case persistenceKey
    }
}

enum Forge2DV14Hardening {
    static let styles = #"""
    .pause:focus-visible,
    .controls button:focus-visible {
      outline: 3px solid rgba(244, 247, 251, .96);
      outline-offset: 3px;
    }
    """#

    static let script = #"""
    // Native button activation from keyboard and assistive technologies can emit
    // `click` without the pointer lifecycle used by the touch controls above.
    // Track the pointer lifecycle explicitly so those clicks remain usable without
    // letting an ordinary touch/pointer activation double-fire the assistive path.
    const assistiveReleaseTimers = { left: 0, right: 0 };
    const pointerActivationControls = new Set();

    function pulseAssistiveDirection(inputKey, timerKey) {
      input[inputKey] = true;
      if (assistiveReleaseTimers[timerKey]) window.clearTimeout(assistiveReleaseTimers[timerKey]);
      assistiveReleaseTimers[timerKey] = window.setTimeout(() => {
        input[inputKey] = false;
        assistiveReleaseTimers[timerKey] = 0;
      }, 180);
    }

    function registerAssistiveActivation(button, action) {
      button.addEventListener("pointerdown", () => {
        pointerActivationControls.add(button.id);
      });
      button.addEventListener("pointercancel", () => {
        pointerActivationControls.delete(button.id);
      });
      button.addEventListener("pointerup", () => {
        window.setTimeout(() => pointerActivationControls.delete(button.id), 0);
      });
      button.addEventListener("click", () => {
        if (pointerActivationControls.delete(button.id)) return;
        action();
      });
    }

    registerAssistiveActivation(controls.left, () => pulseAssistiveDirection("keyboardLeft", "left"));
    registerAssistiveActivation(controls.right, () => pulseAssistiveDirection("keyboardRight", "right"));
    registerAssistiveActivation(controls.jump, queueJump);
    """#
}
