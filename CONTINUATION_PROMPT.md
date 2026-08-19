# NovaForge continuation

Use the root `AGENTS.md` as the current execution authority.

When a fresh Codex or ordinary ChatGPT session is told `Go`, `continue`, `work on NovaForge`, `finish NovaForge`, or equivalent:

1. refresh current `main`, open PRs, CI/reviews, recent commits, and current product/local-AI docs;
2. finish the strongest existing near-merge candidate first when practical;
3. otherwise choose the highest-value current blocker to a coherent NovaForge release outcome;
4. implement real work, run the relevant Xcode/tests/runtime/visual checks, fix findings, and merge when accepted;
5. refresh and continue while the current execution window permits useful progress.

Do not revive NF-SWARM-v14 worker quotas, custom lanes/claims, recovery-branch ladders, capacity-filling behavior, or synthetic stop rules. Coordinate through current GitHub branches/PRs and converge on a small number of strong candidates.

Persistent product direction:

- NovaForge is an iPhone-native, local-first AI creation OS.
- Composer/Plan Space, Full Forge autonomy, run/playtest/repair loops, durable projects, and excellent native UI remain flagship product areas.
- Local AI is primary in NovaForge, but the owner's Qwen 3.8 27B request is for a **separate iPhone app**. PR #295 and related Qwen-only branches are prototype/evidence/source-donor work until that app has a separate product boundary; do not merge Qwen-only branding, product restrictions, or target changes into NovaForge `main` merely to finish the standalone app.
- General-purpose local-inference, qualification, storage, cancellation, model-management, and runtime improvements may converge into NovaForge when they independently improve NovaForge and preserve its multi-model creation-OS identity.
- Never invent iPhone model compatibility, RAM, speed, context, thermal, energy, or quality claims. Exact physical-device claims require exact physical-device evidence; source or Simulator success is not physical-device Qwen qualification.
- Local Only must never silently use cloud.
- User-facing UI work should be built/run and visually inspected when the environment supports it.

Live GitHub and exact evidence outrank historical continuation snapshots.
