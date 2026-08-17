#!/usr/bin/env python3
"""Lock a Core-AI-friendly single-token Qwen3.5 linear-attention layer to HF.

Uses the official 0.8B architecture dimensions and the official Transformers
layer's randomly initialized weights. No checkpoint weights are downloaded.
The zero-history single-token case validates every operation surrounding the
already-qualified recurrent rule: projections, depthwise causal conv, SiLU,
decay/beta, gated RMSNorm, and output projection.
"""
from __future__ import annotations

import math
import torch
import torch.nn.functional as F

from transformers import Qwen3_5TextConfig
from transformers.models.qwen3_5.modeling_qwen3_5 import Qwen3_5GatedDeltaNet

MODEL = "Qwen/Qwen3.5-0.8B"


def l2norm(x: torch.Tensor, eps: float = 1e-6) -> torch.Tensor:
    return x * torch.rsqrt((x * x).sum(dim=-1, keepdim=True) + eps)


def recurrent_step(q, k, v, g, beta, state):
    q = l2norm(q.float()) * (1.0 / math.sqrt(q.shape[-1]))
    k = l2norm(k.float())
    v = v.float()
    state = state.float() * g.float().exp().unsqueeze(-1).unsqueeze(-1)
    memory = (state * k.unsqueeze(-1)).sum(dim=-2)
    delta = (v - memory) * beta.float().unsqueeze(-1)
    state = state + k.unsqueeze(-1) * delta.unsqueeze(-2)
    out = (state * q.unsqueeze(-1)).sum(dim=-2)
    return out, state


def novaforge_step(layer: Qwen3_5GatedDeltaNet, hidden: torch.Tensor):
    batch = hidden.shape[0]
    mixed = F.linear(hidden, layer.in_proj_qkv.weight)
    mixed = mixed.transpose(1, 2)  # [B,C,1]

    # Zero-history single-token causal conv. This exactly matches HF's
    # causal_conv1d_fn(seq=1): left pad kernel-1 zeros, then depthwise conv.
    padded = F.pad(mixed, (layer.conv_kernel_size - 1, 0))
    conv = F.conv1d(
        padded,
        layer.conv1d.weight,
        layer.conv1d.bias,
        groups=layer.conv_dim,
    )
    conv = F.silu(conv).transpose(1, 2)

    query, key, value = torch.split(
        conv,
        [layer.key_dim, layer.key_dim, layer.value_dim],
        dim=-1,
    )
    query = query.reshape(batch, 1, layer.num_k_heads, layer.head_k_dim)[:, 0]
    key = key.reshape(batch, 1, layer.num_k_heads, layer.head_k_dim)[:, 0]
    value = value.reshape(batch, 1, layer.num_v_heads, layer.head_v_dim)[:, 0]

    z = F.linear(hidden, layer.in_proj_z.weight).reshape(
        batch, 1, layer.num_v_heads, layer.head_v_dim
    )[:, 0]
    b = F.linear(hidden, layer.in_proj_b.weight)[:, 0]
    a = F.linear(hidden, layer.in_proj_a.weight)[:, 0]
    beta = b.sigmoid()
    g = -layer.A_log.float().exp() * F.softplus(a.float() + layer.dt_bias)

    if layer.num_v_heads // layer.num_k_heads > 1:
        repeats = layer.num_v_heads // layer.num_k_heads
        query = query.repeat_interleave(repeats, dim=1)
        key = key.repeat_interleave(repeats, dim=1)

    state = torch.zeros(
        batch,
        layer.num_v_heads,
        layer.head_k_dim,
        layer.head_v_dim,
        dtype=torch.float32,
    )
    core, state = recurrent_step(query, key, value, g, beta, state)

    # Official Qwen3NextRMSNormGated: RMS norm first, then learned weight,
    # then SiLU(z) gate in FP32, finally cast back to input dtype.
    dtype = core.dtype
    core_flat = core.reshape(-1, layer.head_v_dim)
    z_flat = z.reshape(-1, layer.head_v_dim)
    core_fp32 = core_flat.float()
    variance = core_fp32.pow(2).mean(-1, keepdim=True)
    normalized = core_fp32 * torch.rsqrt(variance + layer.norm.variance_epsilon)
    gated = layer.norm.weight.float() * normalized
    gated = gated * F.silu(z_flat.float())
    gated = gated.to(dtype).reshape(batch, 1, layer.value_dim)
    output = F.linear(gated, layer.out_proj.weight)
    return output, state


def main() -> None:
    torch.manual_seed(20260817)
    config = Qwen3_5TextConfig.from_pretrained(MODEL)
    assert config.hidden_size == 1024
    assert config.linear_num_key_heads == 16
    assert config.linear_num_value_heads == 16
    assert config.linear_key_head_dim == 128
    assert config.linear_value_head_dim == 128
    assert config.linear_conv_kernel_dim == 4

    layer = Qwen3_5GatedDeltaNet(config, layer_idx=0).eval()
    hidden = torch.randn(1, 1, config.hidden_size, dtype=torch.float32) * 0.35

    with torch.no_grad():
        expected = layer(hidden, cache_params=None, attention_mask=None)
        actual, _ = novaforge_step(layer, hidden)

    diff = (actual - expected).float()
    rrmse = float(diff.square().mean().sqrt() / expected.float().square().mean().sqrt().clamp_min(1e-8))
    max_abs = float(diff.abs().max())
    cosine = float(F.cosine_similarity(actual.reshape(-1), expected.reshape(-1), dim=0))

    print(f"full_linear_layer_rrmse={rrmse:.9f}")
    print(f"full_linear_layer_max_abs={max_abs:.9f}")
    print(f"full_linear_layer_cosine={cosine:.9f}")

    torch.testing.assert_close(actual, expected, rtol=2e-5, atol=2e-5)
    print("PASS: Core-AI-friendly Qwen3.5 single-token linear layer matches Transformers")


if __name__ == "__main__":
    main()
