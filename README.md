# NovaForge

**On-device AI agent workspace for iOS.** SwiftUI + SwiftData + local llama.cpp inference — a liquid-glass command center with a project dashboard, agent chat, file workspace, run history, and a terminal console.

## Stack

- **UI:** SwiftUI (iOS 26, Liquid Glass APIs with fallbacks), 5 switchable themes (Matrix Rain, Midnight Black, White Gold, Arctic Glass, Ember Core)
- **AI:** Local on-device inference via [`swift-llama-cpp`](Vendor/swift-llama-cpp) (llama.cpp xcframework) + optional OpenAI provider
- **Persistence:** SwiftData (`NovaForge.store`)
- **Project:** `AgentPad.xcodeproj`, scheme `AgentPad`, bundle `com.joey.NovaForge`

## Build

```sh
xcodebuild -project AgentPad.xcodeproj -scheme AgentPad -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

## CI

Every push to `main` triggers a cloud-Mac pipeline that builds the app for the iPhone simulator, walks every surface with launch arguments, and captures screenshots + video to the `ci-shots` branch.
