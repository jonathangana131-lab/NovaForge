#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
runner="${COMPANION_LLAMA_RUNNER:-$root/runners/llama-cpp-qwen-runner}"
manifest="${COMPANION_LLAMA_MANIFEST:-$root/qwen3.8-27b.manifest.json}"
output="${1:-${PWD}/QA/companion-llama-cpp-evidence.jsonl}"
exec "$root/benchmark-companion.zsh" --runtime llama-cpp --runner "$runner" --manifest "$manifest" --output "$output" "${@:2}"
