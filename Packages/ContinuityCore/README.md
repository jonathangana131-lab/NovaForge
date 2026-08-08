# ContinuityCore

Pure Swift truth domain for NovaForge V13 issue #40.

This package deliberately does **not** claim that iOS can run NovaForge forever while the app is closed. It models the boundary that later iOS, cloud, paired-Mac, Mission Engine, Live Activity, notification, and background-transfer adapters must obey.

## Guarantees in this slice

- execution leases are bound to exact mission/project/checkpoint/revision identity;
- moving from foreground to system-managed continuation mints a fresh lease;
- when on-device continuation is unavailable or expires, the active lease is revoked and the mission is projected as paused, never still working;
- cloud and paired-Mac handoff are unavailable until a real worker is both verified and authorized;
- handoff cannot bypass a mission decision or blocked state;
- checkpoint advancement invalidates in-flight work and rejects revision regression;
- stale worker results are rejected after pause, expiration, handoff, or checkpoint movement;
- Live Activity semantics can say `working` only when a structurally valid execution lease exists;
- routine progress/stage chatter is suppressed by notification policy while decision, blocked, requested milestone, completion, and requested download-ready events may notify;
- resumable background-transfer state preserves byte progress only when an opaque resume reference actually exists;
- non-resumable failed transfers restart from zero instead of pretending partial bytes are reusable;
- persisted continuity state is schema-versioned and validated fail-closed on decode.

## Not implemented here

This package does not implement ActivityKit, notifications, BackgroundTasks/continued processing, `URLSession`, cloud workers, Mac pairing, or mission persistence. Those platform/product layers must consume this truth domain and provide real capability evidence. Canonical mission/checkpoint identity remains owned by the V13 Mission Engine; adapters map that identity into `ContinuityIdentity`.
