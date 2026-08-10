#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="$repo_root/AgentPad/Services/LocalModelRuntime.swift"
settings="$repo_root/AgentPad/Views/SettingsComponents.swift"

for path in "$runtime" "$settings"; do
  if [[ ! -f "$path" ]]; then
    echo "missing expected source file: ${path#$repo_root/}" >&2
    exit 1
  fi
done

forbidden=(
  "Device proven"
  "physical-device canary proven"
  "The proven iPhone 12 default"
  'case .deviceProven: "checkmark.shield.fill"'
  'case .deviceProven: AgentPalette.green'
  "Built to survive iPhone memory pressure"
  'Same Qwen coder checkpoint · smallest stable footprint'
  'detailStat("Peak cap", variant.estimatedPeakMemoryLabel)'
  'Released this week and built for low-memory coding.'
  'Pinned · Crash-gated for iPhone'
  'Runs offline with capped context for smooth chat.'
  'at a modest quality tradeoff.'
  'when first-prompt stability matters more than model quality.'
)

failed=0
for needle in "${forbidden[@]}"; do
  if grep -nF "$needle" "$runtime" "$settings"; then
    echo "unearned or stale local-model presentation found: $needle" >&2
    failed=1
  fi
done

required=(
  'case .deviceProven: "Qualification pending"'
  'case .deviceProven: "iphone"'
  'Official Qwen coder baseline · exact-device qualification pending'
  'exact-device qualification remains pending until receipt-backed evidence is available.'
  'case .deviceProven: AgentPalette.cyan'
  'Guarded for iPhone memory pressure'
  'Same Qwen coder checkpoint · smallest configured footprint'
  'detailStat("Est. peak", variant.estimatedPeakMemoryLabel)'
  'NovaForge pins an exact GGUF revision and checksum, then caps context and output for its iPhone-targeted profile.'
  'Pinned · guarded on-device load'
  'Installed locally. Runs offline with the configured context cap.'
  'quality must be evaluated separately.'
  'lower-bit quantization is a resource tradeoff, not a qualified quality or stability result.'
)

for needle in "${required[@]}"; do
  if ! grep -Fq "$needle" "$runtime" "$settings"; then
    echo "expected truthful local-model presentation missing: $needle" >&2
    failed=1
  fi
done

if (( failed != 0 )); then
  exit 1
fi

echo "local-model static presentation truth guard passed"
