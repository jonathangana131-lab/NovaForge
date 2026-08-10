# V14 Preview — Normal Local Route Trust Audit

Worker: `GPT56-SOL-NF-V14-LOCAL-ROUTE-AUDIT-0810`  
Protocol: `NF-SWARM-v14`  
Audited source base: `main@37b5305c459907917d1f27ddc7f08168a68c4bbe`  
Date: 2026-08-10

## Verdict

At this audited head, the **normal Chat fresh-run route for `settings.provider == .local` is structurally bound to the on-device AgentSystem local lane and does not contain a hosted-provider fallback binding inside that accepted run**.

The route is:

**Chat send -> AgentSystem fresh request -> `.builtInLocalModel` / `.onDevice` provider descriptor -> `.localSingleCallTools` -> `AgentProductionProviderGatewayFactory.localSingleCallTools` -> one exact `AgentLocalModelProviderTransport` binding -> `LocalModelClient.shared` -> verified local model file -> SwiftLlama `LlamaService`.**

This is strong static source evidence for the normal local provider route. It is **not** a physical-device network-isolation receipt, does not prove that every unrelated app subsystem is offline, and does not qualify any model for iPhone 12 performance/support.

## Source trace

### 1. Normal Chat send uses AgentSystem

`ChatView.sendPrompt()` dispatches through `agentSystemPresentation.startConfigured(...)`. The normal composer does not invoke the legacy `AgentRuntime` provider/tool loop directly.

### 2. Fresh `.local` authority is reconstructed as an on-device route

`AgentSystemFreshRunRequestFactory` validates the selected provider/model against app-owned catalogs. For `.local` it requires a `LocalModelCatalog` variant and reconstructs `.localSingleCallTools(modelID:)`.

For the local tool route, the same factory requires:

- route provenance `.builtInLocalModel`;
- route deployment `.onDevice`;
- strict/typed single-call tool capability;
- no parallel tool calls;
- the local-agent tool registry;
- every selected tool locality stored as `.onDevice`.

The accepted run plan persists that exact route/options/tool-locality authority.

### 3. Production composition refuses local/hosted route substitution

`AgentSystemProductionComposition` handles `.builtInLocalModel` by reconstructing `AgentProductionProviderRouteSelection.localSingleCallTools(modelID:)` and requiring the reconstructed descriptor route to equal the accepted route before returning `AgentProductionProviderGatewayFactory.localSingleCallTools(...)`.

### 4. The local gateway contains one local transport binding only

`AgentProductionProviderGatewayFactory.localSingleCallTools(...)` constructs `AgentLocalModelProviderTransport` using:

- `LocalModelClient.shared`;
- the sealed local tool capability;
- the local tool registry;
- the accepted workspace.

The resulting `AgentProviderTransportRouter` is initialized with a **single** binding: the exact local descriptor -> that local transport. There is no hosted transport in this local gateway bundle.

`AgentProviderTransportRouter.stream(...)` routes by exact adapter ID and complete descriptor equality. It cannot rewrite an endpoint or widen local/hosted authority.

### 5. Local provider transport exposes no hosted request authority

`AgentLocalModelInferenceStreaming` accepts only an `AgentLocalModelInferenceRequest` containing attempt scope, model ID, messages, temperature, and output-token bound. Its app-side inference seam has no URL, credential, hosted adapter, or arbitrary endpoint input.

The production local provider transport resolves a shipped `LocalModelCatalog` descriptor and uses the supplied local inference implementation. It does not construct `AgentHostedProviderTransport`.

### 6. Production inference resolves verified local bytes and SwiftLlama

`LocalModelClient.shared` conforms to the local inference/planning/artifact-verification capabilities. The production path obtains the model URL from `LocalModelArtifactVerifier.shared.verifiedURL(for:)`, whose source describes it as proof that bytes loaded by llama.cpp match the immutable catalog digest.

The client then obtains/creates a `SwiftLlama.LlamaService(modelUrl: modelURL, ...)` and runs local messages through that service when SwiftLlama is available; otherwise the runtime fails rather than switching provider authority.

The catalog includes HTTPS URLs for **model download**, but that is a separate acquisition surface. This audit does not classify model downloading as offline. It establishes only that an accepted normal local inference run is not structurally backed by a hosted-provider fallback.

## Preview classification

- Normal Chat `.local` accepted run routing: **IN APP / canonical AgentSystem path**.
- Accepted local provider descriptor: **on-device deployment**.
- Local tool localities: **on-device**.
- Local gateway hosted fallback binding: **none in audited production factory**.
- Production local inference implementation: **verified local model file -> SwiftLlama service**.
- Physical-device proof that no packets leave the process/device during a Local-only mission: **NOT ESTABLISHED by this static audit**.
- Exact iPhone 12 model compatibility/performance/RAM/thermal/energy: **NOT ESTABLISHED**.
- Forge Compact RAM/context integration: separate active work; **not established by this audit**.

## Remaining Preview acceptance rung

Before marketing or UI makes a stronger **Local Only = no network during mission** claim, capture a physical-device or otherwise authoritative network-isolation receipt for an accepted local run, including tool execution and any background/service behavior relevant to the mission. Model download should remain an explicit separate network action rather than being conflated with inference.

No code change is justified by this audit: the normal local provider routing boundary is already fail-closed in source. The value here is truthful classification and a precise remaining evidence requirement.

## Non-claims

No model is declared supported or qualified on iPhone 12. No tokens/sec, RAM saving, peak memory, thermal, energy, task-success, network packet capture, Forge Compact reduction, or physical-device result is claimed.
