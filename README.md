# NovaForge

**On-device AI agent workspace for iOS.** SwiftUI + SwiftData + local llama.cpp inference — a liquid-glass command center with a project dashboard, agent chat, file workspace, run history, and a terminal console.

## Founding Builder beta

Building an iPhone app and skeptical of black-box AI coding demos? Apply to test NovaForge against a real iPhone development workflow. The application asks what you are building, which iPhone/iOS version you can test on, and what evidence—such as exact file changes, commands, tests, approval gates, or durable run history—you require before trusting an AI agent with a repository.

**[Apply for the NovaForge Founding Builder beta](https://github.com/jonathangana131-lab/NovaForge/issues/new?template=founding-builder.yml)**

The application is a public GitHub issue, not a purchase or guaranteed invitation. Do not include credentials, private repository details, email addresses, or other sensitive information.

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
