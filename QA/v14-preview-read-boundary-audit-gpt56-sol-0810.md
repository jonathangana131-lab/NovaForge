# V14 Preview — Read Boundary Authority Audit

Worker: `GPT56-SOL-NF-V14-CAPSULE-RENDER-0810`  
Protocol: `NF-SWARM-v14`  
Audit base: `main@37b5305c459907917d1f27ddc7f08168a68c4bbe`  
Date: 2026-08-10

## Verdict

The canonical AgentEngine workspace-read boundary is materially stronger than the older legacy read path: `AgentSandboxReadOnlyToolExecutor` delegates to `POSIXWorkspaceReadBackend`, which pins the workspace root and opens descendants descriptor-relative with no-follow/stability checks.

However, `AgentRuntime` still contains a direct construction path for `SandboxToolExecutor(workspace:)`. `SandboxToolExecutor` performs several reads through `SandboxWorkspace` path-based APIs. Therefore the Preview must **not** claim that every normal-agent workspace read is protected by the pinned-fd POSIX boundary until the legacy callsite is either proven unreachable in the accepted production Preview route or migrated/removed.

This audit does **not** claim a production exploit or data exfiltration. It records an unresolved authority-boundary reachability question.

## Evidence

### Canonical AgentEngine read boundary

`AgentPad/Services/AgentSandboxReadOnlyToolExecutor.swift`:

- implements the production `AgentReadOnlyToolExecuting` adapter;
- verifies run lineage, workspace/project identity, registered descriptor identity, effect class, on-device locality, canonical argument digest, decoded typed arguments, and read-only targets;
- delegates reads to `POSIXWorkspaceReadBackend`;
- owns no mutation authority;
- maps backend target-change/unsafe-target/resource-limit failures closed.

`AgentPad/Services/POSIXWorkspaceReadBackend.swift`:

- opens and retains the workspace root with `O_NOFOLLOW`;
- records and revalidates root identity/security metadata;
- opens descendants relative to already-open directories;
- validates opened nodes with descriptor metadata and no-follow checks;
- bounds traversal, read bytes, output bytes, and per-operation resources.

The source comment explicitly states the intended property: replacing a pathname component may make an operation fail, but must not redirect content reads outside the pinned root.

### Legacy workspace path layer

`AgentPad/Tools/SandboxWorkspace.swift` is not weak in the ordinary path-traversal sense. It rejects absolute/traversal paths, resolves symlinks, validates that standardized and resolved paths remain under the workspace root, and its test suite covers direct traversal and symlink escapes.

But `SandboxWorkspace.read(_:)` performs a path validation/resolution step and then opens content by pathname. The type also contains `SandboxReadInterposition`, documented as a deterministic seam for exercising the validation-to-open race in the real legacy reader. That distinction matters: rejecting a symlink at validation time is not equivalent to descriptor-relative authority if a path component can change before open.

`AgentPad/Tools/SandboxToolExecutor.swift` uses this legacy path-based layer for read operations including `read_file`, `read_file_range`, `tail_file`, file info, search/diff/validation helpers, and command-related read behavior.

### Legacy AgentRuntime callsite remains

At the audited head, `AgentPad/Services/AgentRuntime.swift` still contains a detached execution block that constructs:

```swift
let executor = SandboxToolExecutor(workspace: workspace)
let output = try executor.execute(request)
```

This proves the old executor remains callable from `AgentRuntime` source. This audit has **not** yet proven which accepted production Preview routes can reach that block, under which provider/tool mode, or whether newer AgentEngine composition fully bypasses it for the normal user journey.

## What is already covered

The existing `SandboxWorkspaceTests` cover:

- `../` and absolute path rejection;
- symlink escape rejection for direct reads;
- directory/manifest omission of outside-resolving symlinks;
- search omission of unsafe symlinks;
- root-mutation denial and other mutation invariants.

Those are useful regressions, but they are not proof that the legacy validation-to-open race is impossible.

## Safe next closure rung

1. Trace the exact `AgentRuntime` method containing the direct `SandboxToolExecutor` construction to every production caller and provider/tool mode.
2. If the Preview can reach it, add an adversarial test that changes a path component between validation and content open using the existing interposition seam.
3. Route reachable read-only calls through the canonical `AgentSandboxReadOnlyToolExecutor` / `POSIXWorkspaceReadBackend`, or remove the legacy execution path if it is obsolete.
4. Preserve the separate mutation gateway/permit authority; do not broaden a read migration into mutation semantics.
5. Run the normal Preview agent journey plus read-tool regressions before claiming universal pinned-fd read safety.

Do not patch the large/high-contention `AgentRuntime.swift` merely because the legacy callsite exists. Reachability and exact ownership should be resolved first.

## Preview classification

- Canonical AgentEngine read boundary: **IN APP / integrated source path, hardened by pinned-fd backend**.
- Legacy `SandboxToolExecutor` read path: **still present in AgentRuntime; production Preview reachability unresolved by this audit**.
- Universal claim that all Preview reads use pinned-fd authority: **NOT ESTABLISHED**.

## Non-claims

This receipt does not claim an exploitable race, successful escape, leaked data, physical-device reproduction, iPhone 12 result, performance impact, or security incident. It records a source-backed boundary/reachability gap that must be closed before stronger product claims are made.
