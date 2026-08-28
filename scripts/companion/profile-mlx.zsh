#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
runner="${COMPANION_MLX_RUNNER:-$root/runners/mlx-qwen-runner}"
manifest="${COMPANION_MLX_MANIFEST:-$root/qwen3.8-27b.manifest.json}"
output="${1:-${PWD}/QA/companion-mlx-evidence.jsonl}"
exec "$root/benchmark-companion.zsh" --runtime mlx --runner "$runner" --manifest "$manifest" --output "$output" "${@:2}"
