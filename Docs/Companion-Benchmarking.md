# Qwen3.8-27B Power Companion benchmarking

NovaForge offers `Qwen/Qwen3.8-27B` as a text-only Power companion on a private LAN, separately from `Power — On-device streamed (experimental)`. These profiles are launch/measurement helpers for an Apple Silicon host; they never silently replace the on-device route and do not make an A14 claim.

## Contract

Run `scripts/companion/profile-mlx.zsh` and `scripts/companion/profile-llama-cpp.zsh` with an adapter executable. The adapter must be a pinned, executable wrapper for the selected MLX or llama.cpp Metal build and must implement:

```text
--describe-json -> one JSON object on stdout
--run-jsonl ... -> JSONL events, ending in one done object
```

The attestation object must include the exact `model_id`, immutable revision, `runtime`, `context_limit`, `text_only: true`, a capabilities array, and boolean `mtp_supported` / `mtp_verified`. The harness sends no prompts until identity and capability checks pass. A placeholder revision, public/unknown runtime, non-text model, or context mismatch fails closed.

The final `done` event must include measured `ttft_ms`, `prompt_ms`, `decode_ms`, `generated_tokens`, `peak_memory_bytes`, `thermal_before`, `thermal_after`, `quality` (structured), and the selected `mtp_mode`. The adapter should collect thermal and peak-memory values on the host using native tools such as `powermetrics` and `/usr/bin/time -l`, subject to the host’s permissions. Missing measurements invalidate the run.

Both profiles use the same corpus, context (1024 by default), output cap (128), temperature (0.2), top-p (0.95), and seed (42). The corpus is hashed into every evidence record. The harness performs two runs by default so cold/warm behavior can be represented by the adapter; it never infers a winner or synthesizes a quality score.

Native MTP is requested only when the runtime attestation reports both `mtp_supported` and `mtp_verified`. Otherwise the request is explicitly `--mtp disabled`. Do not label speculative or emulated MTP as native.

## Example

```sh
COMPANION_MLX_RUNNER=/absolute/path/to/pinned-mlx-runner \
  scripts/companion/profile-mlx.zsh QA/companion-mlx.jsonl

COMPANION_LLAMA_RUNNER=/absolute/path/to/pinned-llama-runner \
  scripts/companion/profile-llama-cpp.zsh QA/companion-llama.jsonl
```

The checked-in manifest pins base revision `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` and the text-only UD-IQ1_S artifact at `f4480441d4fb4fe2e283c5d1e05d230195afd939`, SHA-256 `ffcaee8ef32a3fc91ac1b57f529f14e3054624c40cfae809437d490aa2cd597d`. Both adapters must attest their exact runtime artifact; do not benchmark an unpinned checkout. Evidence is machine-readable JSONL and must be reviewed together with adapter source, model checksums, host identity, and thermal conditions. No result is a shipping decision by itself.

The shell-only check is `scripts/companion/test-shell-syntax.zsh`. These scripts do not build, install, or run NovaForge and do not assert MLX versus llama.cpp performance.
