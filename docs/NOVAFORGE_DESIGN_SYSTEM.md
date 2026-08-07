# NOVAFORGE DESIGN SYSTEM — PRODUCT RULES

## 1. Design intent
NovaForge should feel like a first-party-quality engineering instrument on iPhone: fast, calm, precise, native, and slightly futuristic.

The visual language serves hierarchy and trust. Avoid dashboard soup, giant hero cards, neon-on-neon, decorative telemetry, repeated pills, excessive blur, tiny gray debug labels, nested cards, and making every row a rounded rectangle.

## 2. Information hierarchy
Every surface answers one question first:
- Forge: What is the mission doing now?
- Workspace: What project content/artifacts are here and what changed?
- History: What actually happened?
- Control: What capabilities/policies are configured?

A secondary fact cannot visually outrank the primary question.

## 3. Forge
Preferred hierarchy:
1. native navigation/title/project scope;
2. compact mission state/route when relevant;
3. conversation content;
4. inline approvals/tool statuses;
5. composer.

Do not reserve permanent large vertical regions for idle telemetry.

Tool calls collapse to a human verb + target/count + status. Expansion shows exact command/arguments/output/evidence. Errors lead with the actionable summary.

Approval shows action, scope, risk, diff/command preview, approve/deny, and consequence. No generic “Allow?” without explaining what changes.

## 4. Workspace
Prefer lists/outlines where they beat cards. Code needs readable monospace, bounded syntax highlighting, diff semantics, search matches, and horizontal behavior that does not wreck vertical navigation.

A changed-files shelf should make “what did this mission touch?” immediately answerable.

## 5. History
Receipts use event hierarchy rather than chat bubbles. Group noise but preserve exact details behind expansion.

Primary event types: mission accepted, provider route, inspection, tool/command, approval, mutation, verification, retry/failure, result.

## 6. Control
Provider/model selection is status-driven: Ready, Needs key, Needs billing, Local model missing, Model unavailable, Route incompatible, Degraded.

Capability language such as Best local / Fast hosted / Deep reasoning / Coding-tool-capable may be used while exact provider/model remains visible. Never hide data-sharing implications.

## 7. Liquid Glass
Use native glass for top-level chrome, floating controls, sheets/toolbars, and transient overlays where hierarchy benefits.

Avoid glass behind every content group, in dense code/log areas, when text contrast suffers, or when Reduce Transparency is enabled.

## 8. Themes
Themes are semantic-token variations, not separate component implementations. Required tokens include background/surface/text hierarchy, accent, success/warning/danger/info, separator, code background, diff states, and approval risk.

All themes must pass contrast and Reduce Transparency requirements. Reduce theme count if maintaining five themes blocks quality.

## 9. Motion and haptics
Motion explains state transition, insertion/removal, expansion, mission progress, or success/failure. No endless decorative motion during work. Respect Reduce Motion.

Haptics should be meaningful and sparse: selection tick, mission start, success/error, approval-needed. Do not haptic-spam stream/tool deltas.

## 10. Empty/loading/error/offline
Every surface needs intentional states. Forge with no model gets one clear setup action. Workspace with no project gets import/create/select. History empty explains receipts. Control provider failure gives a remedy. Offline mode shows honest local vs hosted availability.

## 11. Accessibility
- Dynamic Type without clipping;
- logical VoiceOver order;
- labeled icons;
- no color-only status;
- 44pt targets;
- predictable keyboard focus;
- Reduce Motion/Transparency;
- Increase Contrast;
- accessible code/diff summaries.

## 12. Screenshot review rubric
For every major surface ask:
1. Can I tell what it is for in 2 seconds?
2. Is the current action obvious?
3. Is anything repeated?
4. Is any card/pill decorative?
5. Is content pushed too low?
6. Does it survive long content?
7. Are error/empty/loading states real?
8. Does keyboard presentation work?
9. Does light mode look intentional?
10. Does accessibility preserve hierarchy?

Never approve a screenshot because it “looks futuristic.” Approve it because it is useful, legible, native, and coherent.
