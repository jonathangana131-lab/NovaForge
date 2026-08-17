#!/usr/bin/env python3
"""Numerically lock NovaForge's Core-AI-friendly DeltaNet step to Transformers.

This test intentionally targets the single-token recurrent path used by a draft
model during speculative decode. The implementation uses only ordinary PyTorch
ops (mul/sum/rsqrt/exp), which are the shape of graph we want Core AI to lower.
"""
from __future__ import annotations

import torch

from transformers.models.qwen3_next.modeling_qwen3_next import (
    torch_recurrent_gated_delta_rule,
)


def l2norm(x: torch.Tensor, eps: float = 1e-6) -> torch.Tensor:
    return x * torch.rsqrt((x * x).sum(dim=-1, keepdim=True) + eps)


def novaforge_recurrent_delta(
    query: torch.Tensor,
    key: torch.Tensor,
    value: torch.Tensor,
    g: torch.Tensor,
    beta: torch.Tensor,
    state: torch.Tensor,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Core-AI-friendly equivalent of Transformers' recurrent gated delta rule.

    Input layout follows Qwen3.5: [B, S, H, D] for q/k/v and [B,S,H] for
    g/beta. Persistent state is [B,H,Dk,Dv], kept FP32.
    """
    input_dtype = query.dtype
    q = l2norm(query).transpose(1, 2).contiguous().float()
    k = l2norm(key).transpose(1, 2).contiguous().float()
    v = value.transpose(1, 2).contiguous().float()
    decay = g.transpose(1, 2).contiguous().float()
    step = beta.transpose(1, 2).contiguous().float()

    q = q * (1.0 / (q.shape[-1] ** 0.5))
    s = state.float()
    outputs: list[torch.Tensor] = []

    for token_index in range(q.shape[2]):
        q_t = q[:, :, token_index]
        k_t = k[:, :, token_index]
        v_t = v[:, :, token_index]
        decay_t = decay[:, :, token_index].exp().unsqueeze(-1).unsqueeze(-1)
        beta_t = step[:, :, token_index].unsqueeze(-1)

        s = s * decay_t
        memory_value = (s * k_t.unsqueeze(-1)).sum(dim=-2)
        delta = (v_t - memory_value) * beta_t
        s = s + k_t.unsqueeze(-1) * delta.unsqueeze(-2)
        outputs.append((s * q_t.unsqueeze(-1)).sum(dim=-2))

    out = torch.stack(outputs, dim=2).transpose(1, 2).contiguous().to(input_dtype)
    return out, s


def run_case(seed: int, *, batch: int, seq: int, heads: int, dim: int) -> None:
    generator = torch.Generator().manual_seed(seed)
    q = torch.randn(batch, seq, heads, dim, generator=generator, dtype=torch.float32)
    k = torch.randn(batch, seq, heads, dim, generator=generator, dtype=torch.float32)
    v = torch.randn(batch, seq, heads, dim, generator=generator, dtype=torch.float32)
    # Qwen computes g <= 0. Keep it in a numerically realistic decay range.
    g = -torch.rand(batch, seq, heads, generator=generator, dtype=torch.float32) * 2.5
    beta = torch.sigmoid(torch.randn(batch, seq, heads, generator=generator, dtype=torch.float32))
    initial = torch.randn(batch, heads, dim, dim, generator=generator, dtype=torch.float32) * 0.05

    expected_out, expected_state = torch_recurrent_gated_delta_rule(
        q,
        k,
        v,
        g=g,
        beta=beta,
        initial_state=initial.clone(),
        output_final_state=True,
        use_qk_l2norm_in_kernel=True,
    )
    actual_out, actual_state = novaforge_recurrent_delta(q, k, v, g, beta, initial.clone())

    torch.testing.assert_close(actual_out, expected_out, rtol=2e-6, atol=2e-6)
    torch.testing.assert_close(actual_state, expected_state, rtol=2e-6, atol=2e-6)


def main() -> None:
    torch.set_grad_enabled(False)
    # Decode is the critical speculative path; multi-token cases also prove the
    # state transition composes exactly across a proposal block.
    run_case(1, batch=1, seq=1, heads=2, dim=8)
    run_case(2, batch=1, seq=4, heads=3, dim=16)
    run_case(3, batch=2, seq=7, heads=4, dim=8)

    # Sequential one-token calls must equal one block call. This is essential for
    # keeping a Core AI drafter state resident across accepted target tokens.
    gen = torch.Generator().manual_seed(44)
    q = torch.randn(1, 5, 2, 8, generator=gen)
    k = torch.randn(1, 5, 2, 8, generator=gen)
    v = torch.randn(1, 5, 2, 8, generator=gen)
    g = -torch.rand(1, 5, 2, generator=gen)
    beta = torch.sigmoid(torch.randn(1, 5, 2, generator=gen))
    initial = torch.randn(1, 2, 8, 8, generator=gen) * 0.03

    block_out, block_state = novaforge_recurrent_delta(q, k, v, g, beta, initial.clone())
    state = initial.clone()
    pieces = []
    for index in range(q.shape[1]):
        out, state = novaforge_recurrent_delta(
            q[:, index : index + 1],
            k[:, index : index + 1],
            v[:, index : index + 1],
            g[:, index : index + 1],
            beta[:, index : index + 1],
            state,
        )
        pieces.append(out)
    stepped_out = torch.cat(pieces, dim=1)
    torch.testing.assert_close(stepped_out, block_out, rtol=2e-6, atol=2e-6)
    torch.testing.assert_close(state, block_state, rtol=2e-6, atol=2e-6)

    print("PASS: NovaForge recurrent DeltaNet primitive matches Transformers")
    print("PASS: sequential decode state == block recurrence")


if __name__ == "__main__":
    main()
