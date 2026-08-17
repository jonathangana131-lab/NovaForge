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
EXPECTED_FAMILY_VOCAB_SIZE = 248_320
REQUIRED_SPECIAL_IDS = {
    248_044: "<|endoftext|>",
    248_045: "<|im_start|>",
    248_046: "<|im_end|>",
    248_053: "<|vision_start|>",
    248_054: "<|vision_end|>",
    248_056: "<|image_pad|>",
    248_057: "<|video_pad|>",
}


def fetch(model: str, name: str) -> bytes:
    url = f"https://huggingface.co/{model}/resolve/main/{name}?download=true"
    request = urllib.request.Request(url, headers={"User-Agent": "NovaForge-CoreAI-Qualification/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized_special_entry(entry: object) -> dict | None:
    if not isinstance(entry, dict):
        return None
    return {
        "content": entry.get("content"),
        "lstrip": bool(entry.get("lstrip", False)),
        "normalized": bool(entry.get("normalized", False)),
        "rstrip": bool(entry.get("rstrip", False)),
        "single_word": bool(entry.get("single_word", False)),
        "special": bool(entry.get("special", False)),
    }


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
    draft_added = configs["draft"].get("added_tokens_decoder", {})
    target_added = configs["target"].get("added_tokens_decoder", {})
    for token_id, expected_content in REQUIRED_SPECIAL_IDS.items():
        key = str(token_id)
        draft_entry = normalized_special_entry(draft_added.get(key))
        target_entry = normalized_special_entry(target_added.get(key))
        if draft_entry != target_entry:
            raise SystemExit(
                f"FAIL: special token {token_id} semantics differ: draft={draft_entry!r} target={target_entry!r}"
            )
        if draft_entry is None or draft_entry.get("content") != expected_content:
            raise SystemExit(
                f"FAIL: token {token_id} content drifted: observed={draft_entry!r} expected={expected_content!r}"
            )

    # Generation stop semantics may intentionally use <|im_end|> even though
    # the model config also exposes <|endoftext|>. They only need to match
    # between draft and target for speculative decoding.
    for field in ("eos_token", "pad_token", "bos_token"):
        if configs["draft"].get(field) != configs["target"].get(field):
            raise SystemExit(
                f"FAIL: tokenizer config field {field!r} differs: "
                f"draft={configs['draft'].get(field)!r} target={configs['target'].get(field)!r}"
            )

    # tokenizer.json is the authoritative serialized tokenizer graph. Parse it
    # after the byte-for-byte proof so we also fail on corrupt downloads and can
    # sanity-check the serialized base vocabulary.
    tokenizer = json.loads(payloads["draft"]["tokenizer.json"])
    model = tokenizer.get("model", {})
    vocab = model.get("vocab")
    if not isinstance(vocab, dict):
        raise SystemExit("FAIL: tokenizer.json has no vocabulary map")
    if len(vocab) > EXPECTED_FAMILY_VOCAB_SIZE:
        raise SystemExit(
            f"FAIL: base vocab unexpectedly exceeds family vocabulary: {len(vocab)}"
        )

    print("PASS: Qwen3.5-0.8B and Qwen3.6-27B tokenizer.json are byte-identical")
    print(f"sha256={draft_hash}")
    print(f"serialized_base_vocab_entries={len(vocab)}")
    print(f"eos_token={configs['draft'].get('eos_token')!r}")
    print("PASS: required special-token IDs and generation stop semantics match")
    print("Raw token-ID drafting is tokenizer-compatible, subject to model/export runtime qualification.")


if __name__ == "__main__":
    main()
