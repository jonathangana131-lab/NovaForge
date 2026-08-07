# NOVAFORGE AI PROVIDER CONTRACT
Snapshot: 2026-08-06

## Purpose
This document prevents NovaForge from confusing a provider name or model string with a working agent route. A model is selectable only when a complete route contract exists.

## 1. Canonical RouteDescriptor
Every selectable model must resolve to a structure equivalent to:
- providerID
- adapterID
- exact modelID
- deployment: local | hosted
- provenance: built-in trusted | third-party | custom
- API dialect: responses | chatCompletions | localGrammar | localText | other versioned dialect
- base URL + path family
- authentication mode
- credential Keychain reference
- context window / maximum output if known
- streaming and cancellation support
- tool mode
- reasoning/replay metadata requirements
- retry/rate-limit semantics
- health/catalog freshness
- product support status
- last verified contract version/date.

UI selection is a view over this contract, never a parallel list.

## 2. Support states
SUPPORTED: complete route contract, serializer/parser tests, required tool semantics, normalized errors, and critical product journey evidence.

EXPERIMENTAL: explicit opt-in and clearly incomplete evidence; never silent default/fallback.

LEGACY: decodable/recoverable old settings, not offered fresh until re-accepted.

BROKEN: known failure, blocked before network send with actionable migration.

UNVERIFIED: plausible but insufficient evidence; not recommended/auto-routed.

REMOVED_DO_NOT_OFFER: security/private-contract/obsolete route that must not be newly selected.

## 3. Public OpenAI
- Public documented API endpoints only.
- API key in Keychain.
- API billing is separate from ChatGPT subscription billing.
- Model catalog is refreshed and filtered through capability truth.
- Exact API dialect per model.
- Actionable auth/access/billing/rate-limit/context/timeout/outage errors.
- Raw secret-bearing response bodies do not enter logs/receipts.

Acceptance includes no-key, invalid-key, billing, model-access, context-limit, rate-limit, timeout, cancellation, malformed stream, partial stream and outage fixtures.

## 4. ChatGPT / openAICodex private backend
Main currently contains a `chatgpt.com/backend-api/codex` route.

Permanent rule:
- treat it as LEGACY / REMOVED_DO_NOT_OFFER for the consumer product unless OpenAI publishes a supported contract that explicitly permits this usage;
- never advertise it as “ChatGPT subscription provider” merely because OAuth/HTTP code exists;
- migrate saved selection with a user-visible explanation where needed;
- preserve only enough compatibility to recover/migrate until removal is proven safe.

## 5. OpenCode Zen
Zen is not one universal wire dialect.

Current external contract observed during architecture session:
- multiple GPT-family Zen models use the OpenAI Responses endpoint family;
- many other Zen models use OpenAI-compatible Chat Completions;
- free-suffixed routes may have distinct authentication behavior.

Therefore route selection MUST be based on model contract.

Do not implement:
`provider == Zen -> always /v1/chat/completions`

Implement:
`(provider, exact model) -> verified route descriptor -> serializer/parser/tool capability`

For unknown new Zen models, fetch trusted metadata when available or mark UNVERIFIED. Do not guess a supported dialect.

Some model families may require opaque provider-specific reasoning/replay metadata for tool continuation. Such metadata is protocol data, not user-visible chain-of-thought. Bound it, persist only when necessary, and fail closed if required replay metadata is absent.

## 6. Local llama.cpp
Local route states should distinguish notDownloaded, partial, validating, ready, incompatible, failedRecoverable, and failedPermanent/unsupported.

Requirements:
- resumable download;
- checksum/size/format validation;
- atomic ready transition;
- disk-space preflight;
- cancellation;
- memory-pressure handling;
- context limit enforcement before inference;
- model/device compatibility table;
- measured thermal/battery/performance data;
- model removal/storage reclamation;
- zero hosted fallback in local-only mode.

Local text and local structured-tool/grammar routes are separate capabilities. Only advertise structured tools after compiler/registry/route attestation succeeds.

## 7. OpenRouter and Custom
Generic OpenAI compatibility does not prove NovaForge canonical-agent compatibility.

Until accepted:
- decode existing settings;
- optional text-only experimental support can exist;
- do not promise canonical tool execution;
- do not auto-fallback into them;
- do not include them in supported-agent choices.

Promotion requires stable endpoint/auth, streaming parser, tool semantics, cancellation, error mapping, replay behavior, context/catalog behavior, security review, and deterministic fixtures.

## 8. Capability negotiation
Routing algorithm:
1. derive required capabilities from mission and policy;
2. enumerate SUPPORTED routes only;
3. filter by privacy/provider/project policy;
4. filter by model/dialect/tool compatibility;
5. order by explicit preference and health;
6. expose chosen exact route;
7. fallback only if user/project policy permits;
8. record exact route in receipt.

“Local only” must never cross the deployment boundary. “Implement + test” requires a canonical tool route, approval policy, workspace access, and sufficient context/output capability.

## 9. Health checks
Health dimensions:
- credential present/valid;
- catalog reachable;
- selected model exists;
- route dialect supported;
- request serializer available;
- stream parser available;
- tool capability available;
- quota/access state when discoverable;
- last successful contract smoke;
- network reachability.

User-facing statuses: Ready / Needs key / Needs billing / Model unavailable / Route incompatible / Degraded / Offline / Local model missing.

## 10. Error normalization
Stable categories include cancelled, unauthorized, forbidden/modelAccess, paymentRequired/quota, invalidRequest, modelUnavailable, contextLimit, contentFiltered, rateLimited, timeout, unavailable/outage, transport/offline, malformedResponse, providerInternal, localModelMissing, localModelIncompatible, localMemoryPressure, unknownSanitized.

The user message says what to do next. Receipt stores a sanitized category/code. Credentials and raw sensitive bodies are not persisted.

## 11. Streaming contract
A provider adapter defines event framing, text delta extraction, tool delta extraction, opaque replay metadata handling, finish reason/usage where available, malformed/duplicate event tolerance, cancellation, and EOF/partial response behavior.

UI stream state must hand off exactly once to the persisted assistant message without blink or duplication.

## 12. Retry and fallback
Retry the same route only when category and idempotency permit.
Never retry invalid credentials, explicit cancellation, access forbidden, deterministic invalid request, or missing required tool replay metadata as though they were transient.

Cross-provider fallback:
- forbidden in local-only mode;
- forbidden if it changes data-sharing policy without permission;
- visibly disclosed;
- both failed and replacement routes recorded.

## 13. P0 acceptance matrix
For every SUPPORTED route verify:
- picker visibility and exact model identity;
- model refresh and save/relaunch;
- credential migration;
- fresh send, stream, cancel;
- read tool and approved mutation when advertised;
- denial and tool continuation;
- network interruption;
- 401/402/403/404/408/413/422/429/5xx;
- context overflow;
- app interruption/recovery;
- exact route in receipt;
- no secret leakage.

No route graduates to SUPPORTED without the relevant cells passing.
