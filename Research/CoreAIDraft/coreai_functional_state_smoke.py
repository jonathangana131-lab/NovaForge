#!/usr/bin/env python3
"""Export a tiny ANE-shaped hybrid drafter with explicit functional state I/O.

No model weights are downloaded. The goal is to prove that today's Core AI
TorchConverter accepts the boundary NovaForge needs for Qwen3.5 speculative
drafting: BC1S token input, six-layer-style KV layout, convolution history, and
a 5-D recurrent matrix passed as ordinary input/output tensors.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import torch
from coreai_torch import TorchConverter, get_decomp_table


class TinyFunctionalHybridDraft(torch.nn.Module):
    def forward(
        self,
        token: torch.Tensor,
        key_cache: torch.Tensor,
        value_cache: torch.Tensor,
        delta_conv_state: torch.Tensor,
        delta_recurrent_state: torch.Tensor,
    ):
        # token is BC1S: [B, C, 1, S], S=1 in decode.
        token_kv = token.unsqueeze(1)  # [B, 1, C, 1, 1]
        key_cache_out = torch.cat((key_cache[..., 1:], token_kv), dim=-1)
        value_cache_out = torch.cat((value_cache[..., 1:], token_kv), dim=-1)

        flat = token[:, :, 0, 0]
        conv_token = torch.cat((flat, flat, flat), dim=-1).unsqueeze(1).unsqueeze(-1)
        delta_conv_state_out = torch.cat((delta_conv_state[..., 1:], conv_token), dim=-1)

        key = flat[:, :4]
        value = flat[:, 4:8]
        rank_one = key.unsqueeze(-1) * value.unsqueeze(-2)  # [B, 4, 4]
        rank_one = rank_one.unsqueeze(1).unsqueeze(1)
        rank_one = torch.cat((rank_one, rank_one), dim=2)  # two synthetic heads
        delta_recurrent_state_out = delta_recurrent_state + rank_one

        memory = delta_recurrent_state_out.sum(dim=(-1, -2, -3), keepdim=False)
        memory = memory.reshape(token.shape[0], 1, 1, 1)
        token_out = token + memory

        return (
            token_out,
            key_cache_out,
            value_cache_out,
            delta_conv_state_out,
            delta_recurrent_state_out,
        )


def export_asset(output: Path, dtype: torch.dtype) -> None:
    model = TinyFunctionalHybridDraft().eval().to(dtype=dtype)
    examples = (
        torch.randn(1, 8, 1, 1, dtype=dtype),
        torch.zeros(1, 1, 8, 1, 16, dtype=dtype),
        torch.zeros(1, 1, 8, 1, 16, dtype=dtype),
        torch.zeros(1, 1, 24, 3, dtype=dtype),
        torch.zeros(1, 1, 2, 4, 4, dtype=dtype),
    )

    with torch.no_grad():
        reference = model(*examples)
        assert reference[0].shape == (1, 8, 1, 1)
        assert reference[1].shape == examples[1].shape
        assert reference[2].shape == examples[2].shape
        assert reference[3].shape == examples[3].shape
        assert reference[4].shape == examples[4].shape

    exported = torch.export.export(model, args=examples)
    exported = exported.run_decompositions(get_decomp_table())
    program = (
        TorchConverter()
        .add_exported_program(
            exported,
            input_names=[
                "token",
                "key_cache",
                "value_cache",
                "delta_conv_state",
                "delta_recurrent_state",
            ],
            output_names=[
                "token_out",
                "key_cache_out",
                "value_cache_out",
                "delta_conv_state_out",
                "delta_recurrent_state_out",
            ],
        )
        .to_coreai()
    )
    program.optimize()
    # coreai-core's Asset.save_asset API expects pathlib.Path so it can inspect
    # the .aimodel suffix directly.
    program.save_asset(output)

    if not output.exists():
        raise RuntimeError(f"Core AI asset was not written: {output}")
    print(f"PASS: exported functional hybrid state asset -> {output}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dtype", choices=("float16", "float32"), default="float16")
    args = parser.parse_args()
    dtype = torch.float16 if args.dtype == "float16" else torch.float32
    export_asset(args.output, dtype)


if __name__ == "__main__":
    main()
