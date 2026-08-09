# V14 Visual QA evidence-authority review

Worker: `GPT56-NF-V14-GO-8A08`  
Reviewed main: `92a7340aaff5955523fb4dd72c034fd79de60166`  
Target: `Packages/ForgeVisualQAKit/Sources/ForgeVisualQA/ForgeVisualQA.swift`

## P1 — runtime screenshot/frame evidence is self-declared metadata

`VisualCaptureReceipt` is a public `Codable` value with a public initializer. A caller supplies every field itself, including `evidenceKind`, and `VisualCaptureReceipt.isRuntimeVisualProof` is only:

```swift
public var isRuntimeVisualProof: Bool { evidenceKind.isRuntimeVisualProof }
```

There is no image/frame artifact digest, canonical capture producer receipt, host-only acceptance capability, immutable artifact reference, or provenance check behind `.runtimeScreenshot` / `.runtimeFrameSequence`.

That means decoded/model-authored metadata can label itself runtime visual proof without any screenshot or frame sequence existing.

### Concrete first-minute acceptance laundering

Ordinary external code can:

1. construct a valid-looking `VisualCaptureReceipt` with `evidenceKind: .runtimeScreenshot`;
2. construct one `FirstMinuteObservation(passed: true, captureID: capture.id)` for every visual criterion and `passed: true` for the remaining criterion;
3. construct `FirstMinuteAssessment(capture:observations:)`.

`FirstMinuteAssessment.passes` then becomes `true` because all checks are structural: the enum says runtime screenshot, every criterion exists, none is failed, and the supplied UUIDs match. No screenshot bytes, renderer receipt, pixel evidence, or host acceptance is consulted.

This can falsely satisfy exactly the sort of first-minute visual acceptance that Full Forge / Completion must treat as evidence-backed rather than model-declared.

### Concrete auto-polish completion laundering

A caller can likewise construct:

```swift
AutoPolishPass(capture: fabricatedRuntimeCapture, findings: [], improvementScore: 1)
```

and `AutoPolishPlanner.decide(passes: [pass])` returns `.stop(.acceptancePassed)` solely because the structurally self-labelled capture is considered runtime visual proof and the caller supplied no findings.

The planner is therefore a useful deterministic policy calculator, but its current inputs cannot be treated as authenticated visual acceptance authority.

## P1 — visual regression comparison has no artifact identity/content binding

`VisualRegressionComparator` compares structural metadata (project ID, evidence kind, viewport, accessibility state) but has no screenshot/frame artifact digest to bind the baseline or candidate to actual rendered pixels/frames. Two arbitrary metadata receipts can be declared comparable even when no underlying visual artifacts exist.

Cross-revision comparison itself is reasonable, so this is not a request to require equal `sourceRevision`. The missing boundary is artifact/provenance identity.

## Required closure before Completion/Repair consumes this as visual proof

- Treat public/Codable `VisualCaptureReceipt` as **candidate capture metadata**, not trusted runtime visual proof.
- Introduce a distinct host-authenticated capture acceptance/capability that cannot be minted from candidate Codable fields alone.
- Bind that trusted acceptance to the complete validated capture subject **and** an immutable screenshot/frame artifact identity (content digest / canonical artifact receipt, plus exact capture environment identity where material).
- Make first-minute acceptance and auto-polish `acceptancePassed` require the trusted capture subject rather than `evidenceKind` alone.
- Preserve current structural comparison checks, but require both sides to carry authenticated artifact identity before calling them visual regression evidence.
- Add an external-package adversarial regression proving decoded/model-authored candidate metadata cannot directly mint trusted visual proof.
- Add a no-artifact regression proving a syntactically valid `runtimeScreenshot` candidate with all `passed` observations cannot yield authoritative first-minute acceptance.

## Truth boundary

This is a source/API evidence-authority finding only. It does **not** claim any existing screenshot is fake, does not claim a Simulator/device run occurred, and does not assert visual quality of the app. The point is that the current type/API boundary cannot distinguish genuine runtime capture evidence from caller-authored metadata.

The active stale branch `agent/v14-visual-acceptance-evidence` was checked before recording this review. Its current diff adds acceptance environment/performance/accessibility evidence files but does not modify this live `VisualCaptureReceipt` proof path, so this review does not duplicate an already-implemented capture-authentication repair.
