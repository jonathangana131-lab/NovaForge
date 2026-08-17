#!/usr/bin/env python3
"""Derive and validate the persistent-state contract for Qwen3.5-0.8B drafting.

The proposed Core AI adapter must keep Gated-Delta recurrence/conv state only on
linear-attention layers and KV state only on full-attention layers. This script
fetches the official config and fails if upstream architecture changes invalidate
our shapes or memory budget.
"""
from __future__ import annotations

import json
import urllib.request
from dataclasses import dataclass

MODEL = "Qwen/Qwen3.5-0.8B"
EXPECTED = {
    "layers": 24,
    "linear_layers": 18,
    "full_layers": 6,
    "hidden_size": 1024,
    "linear_num_key_heads": 16,
    "linear_num_value_heads": 16,
    "linear_key_head_dim": 128,
    "linear_value_head_dim": 128,
    "linear_conv_kernel_dim": 4,
    "attention_kv_heads": 2,
    "attention_head_dim": 256,
    "vocab_size": 248_320,
}


def fetch_config() -> dict:
    url = f"https://huggingface.co/{MODEL}/resolve/main/config.json?download=true"
    request = urllib.request.Request(url, headers={"User-Agent": "NovaForge-CoreAI-Qualification/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


@dataclass(frozen=True)
class StateBudget:
    conv_bytes: int
    recurrent_bytes: int
    kv_bytes: int

    @property
    def total_bytes(self) -> int:
        return self.conv_bytes + self.recurrent_bytes + self.kv_bytes


def mib(value: int) -> float:
    return value / (1024 * 1024)


def derive(context_tokens: int = 2048) -> StateBudget:
    raw = fetch_config()
    cfg = raw["text_config"]
    layer_types = cfg["layer_types"]
    linear_layers = sum(kind == "linear_attention" for kind in layer_types)
    full_layers = sum(kind == "full_attention" for kind in layer_types)

    observed = {
        "layers": len(layer_types),
        "linear_layers": linear_layers,
        "full_layers": full_layers,
        "hidden_size": cfg["hidden_size"],
        "linear_num_key_heads": cfg["linear_num_key_heads"],
        "linear_num_value_heads": cfg["linear_num_value_heads"],
        "linear_key_head_dim": cfg["linear_key_head_dim"],
        "linear_value_head_dim": cfg["linear_value_head_dim"],
        "linear_conv_kernel_dim": cfg["linear_conv_kernel_dim"],
        "attention_kv_heads": cfg["num_key_value_heads"],
        "attention_head_dim": cfg["head_dim"],
        "vocab_size": cfg["vocab_size"],
    }
    if observed != EXPECTED:
        raise SystemExit(f"FAIL: upstream Qwen3.5-0.8B architecture drifted:\n{observed!r}\n!=\n{EXPECTED!r}")

    # DeltaNet causal convolution keeps kernel_size-1 previous values for Q/K/V.
    key_dim = cfg["linear_num_key_heads"] * cfg["linear_key_head_dim"]
    value_dim = cfg["linear_num_value_heads"] * cfg["linear_value_head_dim"]
    conv_dim = key_dim * 2 + value_dim
    conv_state_values = linear_layers * conv_dim * (cfg["linear_conv_kernel_dim"] - 1)
    conv_bytes = conv_state_values * 2  # FP16 storage is sufficient for conv history.

    # Qwen3.5 declares mamba_ssm_dtype=float32. Preserve recurrence in FP32 until
    # device validation proves a lower-precision state is numerically safe.
    recurrent_values = (
        linear_layers
        * cfg["linear_num_value_heads"]
        * cfg["linear_key_head_dim"]
        * cfg["linear_value_head_dim"]
    )
    recurrent_bytes = recurrent_values * 4

    # Only six full-attention layers need K/V cache. Keep the draft state small;
    # the 27B target has its own independent llama KV/recurrent state.
    kv_values = (
        2
        * full_layers
        * cfg["num_key_value_heads"]
        * cfg["head_dim"]
        * context_tokens
    )
    kv_bytes = kv_values * 2  # FP16 Core AI draft KV baseline.

    return StateBudget(
        conv_bytes=conv_bytes,
        recurrent_bytes=recurrent_bytes,
        kv_bytes=kv_bytes,
    )


def main() -> None:
    budget = derive(2048)
    if budget.recurrent_bytes > 20 * 1024 * 1024:
        raise SystemExit("FAIL: recurrent draft state exceeded 20 MiB qualification budget")
    if budget.conv_bytes > 1 * 1024 * 1024:
        raise SystemExit("FAIL: conv draft state exceeded 1 MiB qualification budget")
    if budget.kv_bytes > 25 * 1024 * 1024:
        raise SystemExit("FAIL: 2K full-attention KV exceeded 25 MiB qualification budget")
    if budget.total_bytes > 45 * 1024 * 1024:
        raise SystemExit("FAIL: total persistent draft state exceeded 45 MiB qualification budget")

    print("PASS: Qwen3.5-0.8B Core AI draft state contract")
    print(f"conv_state={mib(budget.conv_bytes):.3f} MiB")
    print(f"delta_recurrent_state={mib(budget.recurrent_bytes):.3f} MiB")
    print(f"full_attention_kv_2k={mib(budget.kv_bytes):.3f} MiB")
    print(f"total_persistent_state_2k={mib(budget.total_bytes):.3f} MiB")


if __name__ == "__main__":
    main()
