#!/usr/bin/env python3
"""ANE-safe functional state-layout contract for the Qwen3.5 Core AI drafter.

Apple's current model-authoring guidance for Neural Engine token generation uses
readonly functional cache I/O rather than hidden mutable state across inference
calls. NovaForge therefore passes KV + Gated-Delta state explicitly and receives
updated state explicitly. This also makes speculative rollback deterministic.
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

# These are ordinary model inputs/outputs, not Core AI hidden mutable states.
FUNCTIONAL_INPUT_NAMES = (
    "key_cache",
    "value_cache",
    "delta_conv_state",
    "delta_recurrent_state",
)
FUNCTIONAL_OUTPUT_NAMES = (
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

    # Apple's iOS Neural Engine KV layout: [layers, batch, kv_embed, 1, context].
    # Only Qwen3.5's six full-attention layers participate.
    kv_embed = FULL_KV_HEADS * FULL_HEAD_DIM
    kv = (len(FULL_ATTENTION_LAYER_INDICES), batch_size, kv_embed, 1, context_length)

    # Delta conv keeps only kernel-1 prior values. Recurrence stays FP32 until
    # device PSNR/perplexity qualification proves lower precision is safe.
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
    # Only full-attention KV grows with context. Delta state remains constant-size.
    return {
        "key_cache": (4,),
        "value_cache": (4,),
        "delta_conv_state": (),
        "delta_recurrent_state": (),
    }


def static_specializations(max_context_length: int) -> dict[int, DraftStateShapes]:
    if max_context_length < 256:
        raise ValueError("max context must be at least 256")
    if max_context_length & (max_context_length - 1):
        raise ValueError("max context must be a power of two for deterministic specialization")

    result: dict[int, DraftStateShapes] = {}
    cache = 256
    while cache <= max_context_length:
        result[cache] = shapes(cache)
        cache *= 2
    return result


def output_shape_contract(context_length: int) -> dict[str, tuple[int, ...]]:
    state = shapes(context_length)
    # For the first compiler prototype, return full updated buffers. A later
    # optimized implementation may return only KV token deltas, but it must prove
    # identical semantics before changing this boundary.
    return {
        "key_cache_out": state.key_cache,
        "value_cache_out": state.value_cache,
        "delta_conv_state_out": state.delta_conv_state,
        "delta_recurrent_state_out": state.delta_recurrent_state,
    }


def rollback_bytes_per_snapshot(context_length: int) -> int:
    """Bytes needed for a conservative copy-on-propose state checkpoint.

    KV is FP16, conv history FP16 and recurrent matrix FP32. The first real
    speculative prototype can reduce this with copy-on-write/delta snapshots.
    """
    state = shapes(context_length)
    products = lambda dims: __import__("math").prod(dims)
    return (
        products(state.key_cache) * 2
        + products(state.value_cache) * 2
        + products(state.delta_conv_state) * 2
        + products(state.delta_recurrent_state) * 4
    )


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
    assert output_shape_contract(2048)["delta_recurrent_state_out"] == two_k.delta_recurrent_state
    assert len(FUNCTIONAL_INPUT_NAMES) == len(FUNCTIONAL_OUTPUT_NAMES) == 4

    snapshot_mib = rollback_bytes_per_snapshot(2048) / (1024 * 1024)
    assert snapshot_mib < 45

    print("PASS: Qwen3.5 ANE-safe functional state-layout contract")
    print(f"full_attention_layers={FULL_ATTENTION_LAYER_INDICES}")
    print(f"linear_attention_layers={len(LINEAR_ATTENTION_LAYER_INDICES)}")
    print(f"kv_2k_shape={two_k.key_cache}")
    print(f"delta_conv_shape={two_k.delta_conv_state}")
    print(f"delta_recurrent_shape={two_k.delta_recurrent_state}")
    print(f"conservative_rollback_snapshot_2k={snapshot_mib:.3f} MiB")
    print("PASS: state is explicit functional I/O; only KV has a dynamic context axis")


if __name__ == "__main__":
    main()
