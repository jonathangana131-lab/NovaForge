# NovaForge V14 Preview Readiness — 2026-08-10

Protocol: `NF-SWARM-v14`  
Worker: `GPT56-SOL-NF-V14-PREVIEW-READINESS-0810`  
Audited main: `37b5305c459907917d1f27ddc7f08168a68c4bbe`  
Directive: `docs/NOVAFORGE_V14_PREVIEW_AND_2_0_REWRITE_DIRECTIVE.md`

## Verdict

**HOLD — NOT READY TO CALL THE POLISHED PRE-2.0 PREVIEW COMPLETE.**

The Preview is materially closer than the older NovaForge state: the canonical production chat path, deterministic hosted-provider send coverage, five public effort labels, normal theme persistence/wiring, Local Model surfaces, and broad critical UI journeys exist. But source existence and deterministic fixtures are not the same as release acceptance. The current exact-head Critical workflow is still queued, no real hosted-provider canary was executed by this audit, the strongest effort's accepted work-budget slice remains open rather than on main, several provider/Local truth slices remain open, Local Only has not yet been proven fail-closed against every hosted request path, and fresh all-five visual/device acceptance is still missing.

This document is an evidence index and release gate. It does not create a second product authority and it must be refreshed against live GitHub before a release decision.

## Evidence classes

- **IN APP / INTEGRATED** — the production app path is present on audited `main`.
- **DETERMINISTIC PROOF** — source/package/Simulator fixture coverage can prove wiring without claiming a real network/provider/device result.
- **REAL PROOF** — an actual hosted provider, real authenticated session, physical device, or real captured visual/runtime result was exercised on the named release candidate.
- **PENDING STACK** — useful work exists in an open PR/branch but is not credited to `main`.

## Preview gate matrix

| Preview area | IN APP / INTEGRATED on audited main | Deterministic proof on audited main | Real proof seen in this audit | Current gate |
|---|---|---|---|---|
| Hosted OpenAI / ChatGPT execution | `ChatView.sendPrompt()` enters `AgentSystemPresentationStore.startConfigured`, `AgentSystemFreshRunRequestFactory`, production `AgentSystem`, and `AgentProductionProviderGateway`. OpenAI and ChatGPT production gateway construction is not DEBUG-only. | `AgentPadUITests.testForgeChatSendStreamsOneAssistantBubbleAndClearsRunningState` exercises the canonical production composition with sealed deterministic provider transport and is included by the normal smoke/critical harness. Provider gateway tests cover hosted text/tool envelopes and failure fixtures. | **No.** The opt-in physical hosted-provider and Simulator ChatGPT canaries exist, but this worker did not execute them and found no exact release-candidate receipt that can be promoted here. | **BLOCKED for release acceptance** until at least one intended Preview hosted route completes a real authenticated/network canary on the release candidate and persistence/history is proven. |
| Provider selection / failure truth | Public provider and production routing infrastructure exists. | Provider/failure contracts exist, including explicit provider HTTP error handling work in PR #12. | No real-provider error matrix run was produced here. | **PENDING STACK.** PR #12 remains an open draft and must not be counted as merged acceptance. PR #219 separately owns sealed provider+model+dialect route authority and is also open draft. Recompose/merge only after review + exact-head checks. |
| Effort control | User-facing control on main is `Low / Medium / High / Extra High / Ultra`; the fifth stop retains internal `.ultraCode` orchestration and strongest supported model reasoning selection. | `QA/v14-preview-effort-ultra-receipt.md`, `scripts/verify_v14_preview_effort_contract.sh`, and the dedicated workflow guard the naming/persistence/request-path contract. | No physical interaction/performance claim from this audit. | **PARTIAL.** Public naming/selection is on main. PR #216 is still open for a real accepted-run work-budget difference across all five stops; until that slice is integrated and green, do not describe every stop as fully closed end-to-end. PR #217 also keeps strongest-mode capability copy truthful. |
| Local AI / Local Model Center | Local model UI/runtime surfaces are present and qualification-pending semantics have already been strengthened on main ancestry. | Existing source/test guards distinguish configured/observed state from device qualification. | **No iPhone 12 A14 inference qualification was produced here.** | **PENDING.** PR #191 and Preview copy follow-up #221 remain open. Local AI can be shown as available/experimental where truthful, but the Preview must not claim iPhone-12 stability, speed, RAM savings, quality, or qualification without exact-device evidence. |
| Local Only privacy / routing | Privacy intent exists in the broader Composer/Plan lineage, but this audit does not credit prompt prose as routing authority and does not claim the current production send path is fully bound to typed Local Only policy. | No exact release-candidate adversarial proof was found here that covers initial dispatch plus retry/fallback/auth refresh/catalog refresh/tool follow-ups while Local Only is active. | **No.** No real Local Only journey with a proven zero-hosted-request counter was executed by this audit. | **BLOCKED.** A Local Only accepted run must bind typed local-only policy to an exact local route, fail closed if a hosted provider/model remains configured, prevent every hosted request attempt across retries/fallbacks/refresh/follow-ups, and persist the exact local route in the accepted run/session receipt. This privacy gate is independent from iPhone 12 model qualification/performance. |
| Themes | Exactly five normal Preview worlds are wired: Matrix Rain, Midnight Black, White Gold, Arctic Glass, Ember Core. Storage/default/normalization/Settings application paths are guarded. | Main push run `31381140088` for `V14 Preview theme contract` completed **success** on audited head. Existing UI coverage has interactive Matrix -> Midnight hooks. | No fresh all-five exact-head Simulator screenshot sweep or physical-device sweep was produced here. | **SOURCE CONTRACT GREEN; VISUAL ACCEPTANCE PENDING.** |
| Launch + core navigation/chat flows | Launch, Home/chat, Composer, Control, Files/History and production agent composition are present. | `scripts/codex-test.sh` includes launch, canonical send, provider/model repair, effort picker, failure/recovery and broader critical journeys. | No exact-head device run from this audit. | **WAITING ON CURRENT CI.** Main CI run `31381140230` for audited head was **queued** at audit time. Queued is not green. |
| Session persistence / relaunch | Persistence infrastructure exists for provider/model/workspace/project and existing cold-launch journeys exist. | Unit/UI coverage exists. | No fresh exact-head acceptance result seen here. | **PENDING STACK.** PR #220 owns the independent Preview session-relaunch acceptance lane. Do not duplicate it. |
| Run / artifact experience | Existing Run/artifact surfaces and deterministic UI journeys exist. | Current repository tests cover artifact/run interactions at varying depth. | No new runtime/screenshot/physical-device acceptance was produced here. | **PARTIAL.** Preview may expose the existing coherent Run path, but must not present Full Forge/self-play/Completion evidence as finished Preview functionality unless actual receipts exist. |
| Visual polish / accessibility | The app already has substantial first-party iOS styling, theme worlds, accessibility IDs, and screenshot-tour infrastructure. | Theme contract is green; screenshot/critical workflows exist. | No fresh exact-head all-major-surface screenshot critique, accessibility sweep, frame-pacing/performance sweep, or physical-device visual acceptance was produced here. | **BLOCKED for polished-release claim.** |

## Current exact-head CI state

For audited `main@37b5305c459907917d1f27ddc7f08168a68c4bbe`:

- `V14 Preview theme contract` run `31381140088`: **SUCCESS**.
- normal `CI` run `31381140230`: **QUEUED** at audit time.

No result from an older head substitutes for the queued current-head CI gate.

## Existing real-provider proof hooks

The application UI test target already contains opt-in canaries rather than a parallel fake product path:

- `testPhysicalHostedProviderCanaryReturnsRealResponse` — preserves the selected hosted provider/phone credential, sends a per-run nonce, requires that nonce in the completed assistant response, and rejects local fallback/generic transport failure.
- `testSimulatorChatGPTProviderCanaryCompletesAndPersists` — requires a pre-authorized ChatGPT Simulator session, explicitly selects ChatGPT + GPT-5.5, requires the exact assistant response, then requires History to show the latest mission as `Completed`.
- `testSimulatorChatGPTUltraCodeCanaryCompletesAndPersists` — extends the real ChatGPT route through the strongest orchestration path.

Their existence is useful. **They are not a pass receipt until actually executed against the chosen release candidate with the required authorization/environment.**

## Do-not-double-count pending stacks

At audit time, the following relevant Preview work is open and therefore **not** credited as main/integrated:

- PR #12 — phone provider/model/failure reliability and exact-head Critical gate;
- PR #191 — remaining Local Model Center static-truth labels;
- PR #215 — positive strongest-reasoning capability regression for exact supported model paths;
- PR #216 — five-stop accepted run budget behavior;
- PR #217 — truthful Ultra capability copy;
- PR #219 — sealed provider + exact-model + dialect route authority;
- PR #220 — session relaunch acceptance lane;
- PR #221 — Local memory-pressure copy truth.

Open work can be excellent and still is not release-candidate integration evidence.

## Preview release exit criteria

Do not flip this receipt to READY until one exact release-candidate head satisfies all of the following:

1. **Current-head Critical CI is green** with the normal app/unit/critical Simulator matrix; no queued, stale-head, or cancelled run is substituted.
2. **One intended hosted route is proven for real** on the release candidate: authenticated request -> streamed assistant output -> clean idle recovery -> durable History/session persistence, with no hidden Local fallback.
3. **Provider selection/failure truth is integrated** from the canonical owner lineages and revalidated on current main; unsupported/deprecated routes are not offered as supported.
4. **Five effort stops have real bounded behavior**, not only labels. Ultra remains the strongest bounded mode while provider-native reasoning stays capability-clamped rather than fabricated.
5. **Local AI is truthful and usable at its proven level.** If the Preview is advertised as having working/good Local AI on iPhone 12, an exact iPhone 12/iOS/model/runtime/quant/context run must prove load + inference + memory/thermal behavior. Otherwise the UI must stay qualification-pending/experimental and say what is actually proven.
6. **Local Only is a typed fail-closed routing property, not prompt text.** An accepted Local Only run must bind the accepted Privacy authority to an exact local route; reject a still-configured hosted provider/model; prevent hosted dispatch across initial send, retries, fallback, auth refresh, catalog refresh, and tool/agent follow-ups; persist the exact local route in the run/session receipt; and pass an adversarial canary showing **zero hosted provider request attempts** through provider-failure/model-missing/retry paths. This gate is separate from exact-device Local model qualification.
7. **Cold relaunch preserves the effective configured route/project/workspace state** in a visible end-to-end acceptance journey.
8. **All five themes receive fresh release-candidate visual checks** on the target compact iPhone layout; major Composer/chat/Control/History/Run states are screenshot-critiqued, accessibility-checked, and repaired if needed.
9. **No unresolved critical/high Preview blocker** is hidden behind a green narrow contract workflow.
10. **The final release verdict names its evidence.** Source guards, deterministic Simulator fixtures, real provider receipts, Local Only zero-egress proof, physical-device Local proof, screenshots, accessibility, and performance evidence remain separate classes.

## What this means for the user-testable Preview

The fastest honest path is not to wait for deep 2.0 Full Forge closure. Finish the normal hosted-agent path, real five-stop effort behavior, truthful Local AI, fail-closed Local Only routing, relaunch/session reliability, five-theme visual sweep, and one exact release-candidate acceptance pass. Then ship that polished Preview for hands-on testing while the clean 2.0 rewrite proceeds behind it.

Deep Crash Doctor, autonomous self-play, Completion Constitution, beyond-RAM experiments, and other V14 Full Forge work remain valuable, but they must not be used to postpone this Preview unless a concrete Preview blocker directly depends on them.

## Audit truth boundary

This receipt is based on live GitHub source/PR/workflow inspection at the audited SHA. It does not claim Xcode/Simulator execution from this worker environment, physical iPhone execution, real-provider network success, Local Only zero-egress proof, Local model qualification, screenshot acceptance, accessibility acceptance, or measured performance. Refresh all statuses before changing the verdict.
