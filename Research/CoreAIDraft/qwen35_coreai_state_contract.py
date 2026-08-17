#!/usr/bin/env python3
"""Model-independent state-layout contract for the Qwen3.5 Core AI drafter.

This describes the state shapes we will feed Apple Core AI. It deliberately does
not import model weights. The contract keeps KV only for full-attention layers
and gives Gated-Delta layers their own fixed conv/recurrent states.
"""
from __future__ import annotations

from dataclasses import dataclass

FULL_ATTENTION_LAYER_INDICES = (3, 7, 11, 15, 19, 23)
LINEAR_ATTENTION_LAYER_INDICES = tuple(i for i in range(24) if i not in FULL_ATTENTION_LAYER_INDICES)

HIDDEN_SIZE = 1024
FULL_KV_HEADS = 2
FULL_HEAD_DIM = 256
LINEAR_HEADS = 16
LINEAR_KEY_DIM = 128
LINEAR_VALUE_DIM = 128
CONV_KERNEL = 4
CONV_CHANNELS = LINEAR_HEADS * LINEAR_KEY_DIM * 2 + LINEAR_HEADS * LINEAR_VALUE_DIM

STATE_NAMES = (
    "key_cache",
    "value_cache",
    "delta_conv_state",
    "delta_recurrent_state",
)
STATE_OUTPUT_NAMES = (
    "key_cache_out",
    "value_cache_out",
    "delta_conv_state_out",
    "delta_recurrent_state_out",
)


@dataclass(frozen=True)
class DraftStateShapes:
    key_cache: tuple[int, ...]
    value_cache: tuple[int, ...]
    delta_conv_state: tuple[int, ...]
    delta_recurrent_state: tuple[int, ...]


def shapes(context_length: int, batch_size: int = 1) -> DraftStateShapes:
    if context_length <= 0 or batch_size <= 0:
        raise ValueError("context_length and batch_size must be positive")

    # Apple iOS Qwen layout: [layers, batch, kv_embed, 1, context].
    kv_embed = FULL_KV_HEADS * FULL_HEAD_DIM
    kv = (len(FULL_ATTENTION_LAYER_INDICES), batch_size, kv_embed, 1, context_length)

    # Delta conv keeps only kernel-1 history. The recurrent state is always
    # FP32 initially because Qwen's config declares mamba_ssm_dtype=float32.
    conv = (
        len(LINEAR_ATTENTION_LAYER_INDICES),
        batch_size,
        CONV_CHANNELS,
        CONV_KERNEL - 1,
    )
    recurrent = (
        len(LINEAR_ATTENTION_LAYER_INDICES),
        batch_size,
        LINEAR_HEADS,
        LINEAR_KEY_DIM,
        LINEAR_VALUE_DIM,
    )
    return DraftStateShapes(kv, kv, conv, recurrent)


def dynamic_axes() -> dict[str, tuple[int, ...]]:
    # Only full-attention KV grows with context. Delta state is recurrent and
    # remains constant-size no matter how long the session is.
    return {
        "key_cache": (4,),
        "value_cache": (4,),
        "delta_conv_state": (),
        "delta_recurrent_state": (),
    }


def static_specializations(max_context_length: int) -> dict[int, DraftStateShapes]:
    if max_context_length < 256:
        raise ValueError("max context must be at least 256")
    result: dict[int, DraftStateShapes] = {}
    cache = 256
    while cache <= max_context_length:
        result[cache] = shapes(cache)
        cache *= 2
    if max(result) != max_context_length and max_context_length & (max_context_length - 1) == 0:
        raise AssertionError("power-of-two max context must be represented exactly")
    return result


def main() -> None:
    assert FULL_ATTENTION_LAYER_INDICES == (3, 7, 11, 15, 19, 23)
    assert len(LINEAR_ATTENTION_LAYER_INDICES) == 18
    assert CONV_CHANNELS == 6144

    two_k = shapes(2048)
    assert two_k.key_cache == (6, 1, 512, 1, 2048)
    assert two_k.value_cache == two_k.key_cache
    assert two_k.delta_conv_state == (18, 1, 6144, 3)
    assert two_k.delta_recurrent_state == (18, 1, 16, 128, 128)
    assert dynamic_axes()["delta_recurrent_state"] == ()
    assert list(static_specializations(2048)) == [256, 512, 1024, 2048]

    # These names intentionally differ from Apple's stock two-state Qwen3
    # contract and will be mirrored by the actual BaseForCausalLMForiOS subclass.
    assert len(STATE_NAMES) == len(STATE_OUTPUT_NAMES) == 4

    print("PASS: Qwen3.5 Core AI state-layout contract")
    print(f"full_attention_layers={FULL_ATTENTION_LAYER_INDICES}")
    print(f"linear_attention_layers={len(LINEAR_ATTENTION_LAYER_INDICES)}")
    print(f"kv_2k_shape={two_k.key_cache}")
    print(f"delta_conv_shape={two_k.delta_conv_state}")
    print(f"delta_recurrent_shape={two_k.delta_recurrent_state}")
    print("PASS: only KV has a dynamic context axis")


if __name__ == "__main__":
    main()
