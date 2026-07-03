#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail

SIMULATOR_ID="${SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"

device_line="$(xcrun simctl list devices | grep -F "$SIMULATOR_ID" | head -n 1 || true)"
if [[ -z "$device_line" ]]; then
  echo "Simulator $SIMULATOR_ID was not found." >&2
  exit 1
fi

echo "$device_line"
if [[ "$device_line" == *"(Booted)"* ]]; then
  echo "Simulator $SIMULATOR_ID is still booted." >&2
  exit 1
fi

sleep 0.3

lingering="$(
  {
    pgrep -fl 'NovaForge\.app/NovaForge' || true
    pgrep -fl '[c]odex-fast-screenshot\.sh' || true
    pgrep -fl '[c]odex-sim-tour\.sh' || true
    pgrep -fl '[x]codebuild' || true
    pgrep -fl '[s]imctl' || true
  } | sort -u
)"

if [[ -n "$lingering" ]]; then
  echo "Lingering NovaForge/simulator proof helpers:" >&2
  print -r -- "$lingering" >&2
  exit 1
fi

echo "Simulator and proof helpers are clean."
