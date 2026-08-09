# V14 History quality-evidence trust review

Worker: `GPT56-NF-V14-GO-8A08`  
Reviewed PR: `#149`  
Reviewed head: `db6fad6beed8a79dab400bd07e966ee58f1bc505`

## P1 — accepted quality state is publicly mintable from opaque candidate fields

The projection correctly avoids persisting an accepted-quality bit and correctly keeps producer receipt identity opaque. However, the public API does not enforce the host-accepted boundary described by the type names and comments.

Both authority-bearing construction steps are public:

- `ForgeHistoryAcceptedQualityEvidenceReference.init(kind:producerReceiptReference:artifactReference:)`
- `ForgeHistoryCheckpointQualityBinding.init(projectID:checkpointID:evidence:)`

Their inputs are all ordinary public values. `ForgeHistoryProducerReceiptReference` validates only transport-safe string shape; it does not authenticate an Accessibility/Performance producer receipt. The projector then accepts those caller-built bindings and emits `ForgeHistoryAcceptedQualityTimelineProjection` / `ForgeHistoryCheckpointQualityState` carrying the same values as **accepted** quality evidence.

Non-`Codable` storage prevents direct decoding of these wrapper types, but it does not make their public construction host-only. Ordinary external code can recreate the accepted wrapper immediately after decoding or inventing the constituent project/checkpoint/receipt values.

### Concrete laundering path

Conceptually, normal external code can do:

```swift
let arbitraryReceipt = try ForgeHistoryProducerReceiptReference("not-authenticated")
let claim = ForgeHistoryAcceptedQualityEvidenceReference(
    kind: .accessibility,
    producerReceiptReference: arbitraryReceipt
)
let binding = try ForgeHistoryCheckpointQualityBinding(
    projectID: timeline.projectID,
    checkpointID: timeline.checkpoints[0].id,
    evidence: [claim]
)
let accepted = try ForgeHistoryAcceptedQualityTimelineProjector.project(
    timeline: timeline,
    acceptedQuality: [binding]
)
```

If the checkpoint/project identities are structurally valid, History now exposes an `AcceptedQuality` projection although no canonical Accessibility producer was consulted.

The optional artifact guard does not close this: `artifactReference == nil` is allowed, and even when supplied the projector only proves that the artifact is attached to the checkpoint, not that the named quality producer accepted that artifact/receipt for the current quality policy.

## Why this matters

History/Time Machine is meant to preserve already-accepted quality truth without becoming a second Accessibility/Performance authority. As written, it can instead become a second authority because the acceptance wrapper itself is mintable by any consumer.

This is the same trust distinction NovaForge has already needed elsewhere: non-Codable prevents persisted wrapper replay; it does not prove who may mint the wrapper in memory.

## Required closure before promotion

Choose one explicit boundary and enforce it in the API:

1. **Host-only accepted binding:** make accepted evidence/binding construction module-internal and expose a narrow adapter that consumes an already-unforgeable canonical Accessibility/Performance acceptance capability/receipt; or
2. **Candidate-only History projection:** keep constructors public but rename/document the values as untrusted candidate/reference metadata and ensure no downstream UI/Completion/restore path treats the projection as accepted quality until a separate trusted producer adapter has revalidated it.

For the intended `AcceptedQuality...` contract, option 1 is the stronger fit.

Add an external-package compile/adversarial regression proving ordinary `import ForgeHistoryCore` code cannot turn arbitrary receipt-reference strings into the type used by History to expose accepted quality state.

Also keep the current useful protections:
- exact project/checkpoint binding;
- unknown/duplicate checkpoint rejection;
- one quality kind per checkpoint;
- canonical checkpoint ordering;
- optional quality artifact must already be attached to the canonical checkpoint;
- no re-scoring or narrowing of producer receipt identity.

## Truth boundary

This finding does not assert any accessibility/performance producer receipt is invalid, and it does not challenge the package's 43/43 debug/release test result. It is an API authority/provenance issue not covered by those tests. No Xcode, Simulator, physical-device, accessibility, or performance acceptance is claimed here.
