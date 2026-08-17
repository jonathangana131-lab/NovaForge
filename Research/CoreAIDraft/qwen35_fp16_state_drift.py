#!/usr/bin/env python3
"""Stress-test FP16 persisted DeltaNet state against FP32 recurrence.

This is not a model-quality claim. It is a pre-export numerical gate for the
ANE-friendly state choice: after every decode token, the candidate path rounds
the recurrent matrix to FP16 exactly as a functional Core AI state boundary
would. The FP32 path is the correctness reference.
"""
from __future__ import annotations

import math
import torch


def l2norm(x: torch.Tensor, eps: float = 1e-6) -> torch.Tensor:
    return x * torch.rsqrt((x * x).sum(dim=-1, keepdim=True) + eps)


def step(
    q: torch.Tensor,
    k: torch.Tensor,
    v: torch.Tensor,
    g: torch.Tensor,
    beta: torch.Tensor,
    state: torch.Tensor,
) -> tuple[torch.Tensor, torch.Tensor]:
    # Shapes: q/k/v [B,H,D], g/beta [B,H], state [B,H,D,D].
    q = l2norm(q.float()) * (1.0 / math.sqrt(q.shape[-1]))
    k = l2norm(k.float())
    v = v.float()
    state = state.float() * g.float().exp().unsqueeze(-1).unsqueeze(-1)
    memory_value = (state * k.unsqueeze(-1)).sum(dim=-2)
    delta = (v - memory_value) * beta.float().unsqueeze(-1)
    state = state + k.unsqueeze(-1) * delta.unsqueeze(-2)
    out = (state * q.unsqueeze(-1)).sum(dim=-2)
    return out, state


def relative_rmse(actual: torch.Tensor, reference: torch.Tensor) -> float:
    numerator = torch.mean((actual.float() - reference.float()) ** 2).sqrt()
    denominator = torch.mean(reference.float() ** 2).sqrt().clamp_min(1e-8)
    return float(numerator / denominator)


def cosine(actual: torch.Tensor, reference: torch.Tensor) -> float:
    a = actual.float().reshape(-1)
    b = reference.float().reshape(-1)
    return float(torch.nn.functional.cosine_similarity(a, b, dim=0))


def run(seed: int, tokens: int = 2048) -> tuple[float, float, float]:
    gen = torch.Generator().manual_seed(seed)
    batch, heads, dim = 1, 4, 32
    fp32_state = torch.randn(batch, heads, dim, dim, generator=gen) * 0.01
    fp16_state = fp32_state.to(torch.float16)

    reference_outputs = []
    candidate_outputs = []
    for _ in range(tokens):
        q = torch.randn(batch, heads, dim, generator=gen) * 0.6
        k = torch.randn(batch, heads, dim, generator=gen) * 0.6
        v = torch.randn(batch, heads, dim, generator=gen) * 0.5

        # Qwen's decay exponent is non-positive. Keep the stress distribution
        # near the long-memory regime where state-rounding error can accumulate.
        g = -(torch.rand(batch, heads, generator=gen) * 0.08 + 0.002)
        beta = torch.sigmoid(torch.randn(batch, heads, generator=gen))

        ref_out, fp32_state = step(q, k, v, g, beta, fp32_state)
        cand_out, candidate_state_fp32 = step(q, k, v, g, beta, fp16_state)
        # Functional Core AI boundary: persist state in FP16 between calls.
        fp16_state = candidate_state_fp32.to(torch.float16)
        reference_outputs.append(ref_out)
        candidate_outputs.append(cand_out)

    reference = torch.stack(reference_outputs)
    candidate = torch.stack(candidate_outputs)
    output_rrmse = relative_rmse(candidate, reference)
    output_cosine = cosine(candidate, reference)
    state_rrmse = relative_rmse(fp16_state.float(), fp32_state)
    return output_rrmse, output_cosine, state_rrmse


def main() -> None:
    torch.set_grad_enabled(False)
    observed = [run(seed) for seed in (17, 29, 43)]
    worst_output_rrmse = max(item[0] for item in observed)
    worst_cosine = min(item[1] for item in observed)
    worst_state_rrmse = max(item[2] for item in observed)

    print("FP16 persisted DeltaNet state stress results (2048 decode steps):")
    for index, (out_err, out_cos, state_err) in enumerate(observed, start=1):
        print(
            f"case{index}: output_rrmse={out_err:.6f} "
            f"output_cosine={out_cos:.8f} state_rrmse={state_err:.6f}"
        )

    # Conservative pre-export gate. A real Qwen3.5 layer/benchmark must still
    # pass before production enables FP16 recurrence on ANE.
    if worst_output_rrmse > 0.02:
        raise SystemExit(f"FAIL: FP16 persisted-state output RRMSE too high: {worst_output_rrmse:.6f}")
    if worst_cosine < 0.999:
        raise SystemExit(f"FAIL: FP16 persisted-state output cosine too low: {worst_cosine:.8f}")
    if worst_state_rrmse > 0.05:
        raise SystemExit(f"FAIL: FP16 persisted-state matrix RRMSE too high: {worst_state_rrmse:.6f}")

    print("PASS: synthetic long-horizon FP16 recurrent-state drift gate")
    print("NOTE: real-layer PSNR/perplexity qualification is still required.")


if __name__ == "__main__":
    main()
