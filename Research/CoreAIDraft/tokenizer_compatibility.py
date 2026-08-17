#!/usr/bin/env python3
"""Fail-closed proof that the proposed Core AI draft and llama target tokenize identically.

This deliberately downloads tokenizer assets only — never model weights. True
speculative verification requires raw token IDs to mean the same thing in both
models; matching model-family names or vocabulary sizes is not sufficient.
"""
from __future__ import annotations

import hashlib
import json
import urllib.request

MODELS = {
    "draft": "Qwen/Qwen3.5-0.8B",
    "target": "Qwen/Qwen3.6-27B",
}
FILES = ("tokenizer.json", "tokenizer_config.json")
EXPECTED_TOKENIZER_SHA256 = "5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42"
EXPECTED_VOCAB_SIZE = 248_320
EXPECTED_SPECIAL_IDS = {
    "eos_token_id": 248_044,
    "pad_token_id": 248_044,
}


def fetch(model: str, name: str) -> bytes:
    url = f"https://huggingface.co/{model}/resolve/main/{name}?download=true"
    request = urllib.request.Request(url, headers={"User-Agent": "NovaForge-CoreAI-Qualification/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    payloads: dict[str, dict[str, bytes]] = {}
    for role, model in MODELS.items():
        payloads[role] = {name: fetch(model, name) for name in FILES}

    draft_hash = sha256(payloads["draft"]["tokenizer.json"])
    target_hash = sha256(payloads["target"]["tokenizer.json"])
    if draft_hash != target_hash:
        raise SystemExit(f"FAIL: tokenizer.json SHA mismatch: draft={draft_hash} target={target_hash}")
    if draft_hash != EXPECTED_TOKENIZER_SHA256:
        raise SystemExit(
            "FAIL: tokenizer asset changed upstream; re-qualify before enabling raw-token speculation: "
            f"observed={draft_hash} expected={EXPECTED_TOKENIZER_SHA256}"
        )

    configs = {
        role: json.loads(files["tokenizer_config.json"])
        for role, files in payloads.items()
    }
    for role, config in configs.items():
        added = config.get("added_tokens_decoder", {})
        end = added.get(str(EXPECTED_SPECIAL_IDS["eos_token_id"]))
        if not isinstance(end, dict) or end.get("content") != "<|endoftext|>":
            raise SystemExit(f"FAIL: {role} special-token map drifted for endoftext")
        if config.get("eos_token") not in ("<|endoftext|>", None):
            raise SystemExit(f"FAIL: {role} eos token drifted: {config.get('eos_token')!r}")

    # tokenizer.json is the authoritative serialized tokenizer graph. Parse it
    # after the byte-for-byte proof so we also fail on corrupt downloads and can
    # check the vocabulary cardinality explicitly.
    tokenizer = json.loads(payloads["draft"]["tokenizer.json"])
    model = tokenizer.get("model", {})
    vocab = model.get("vocab")
    if not isinstance(vocab, dict):
        raise SystemExit("FAIL: tokenizer.json has no vocabulary map")
    if len(vocab) > EXPECTED_VOCAB_SIZE:
        raise SystemExit(
            f"FAIL: base vocab unexpectedly exceeds declared family vocabulary: {len(vocab)}"
        )

    print("PASS: Qwen3.5-0.8B and Qwen3.6-27B tokenizer.json are byte-identical")
    print(f"sha256={draft_hash}")
    print(f"serialized_base_vocab_entries={len(vocab)}")
    print("Raw token-ID drafting is tokenizer-compatible, subject to model/export runtime qualification.")


if __name__ == "__main__":
    main()
