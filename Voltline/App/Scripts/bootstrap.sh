#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install with: brew install xcodegen" >&2
  exit 1
fi

xcrun swift Scripts/generate_app_icons.swift Resources/Assets.xcassets/AppIcon.appiconset
xcodegen generate --spec project.yml

echo "Generated $ROOT/VoltlineGame.xcodeproj"
echo "Open the project, select the VoltlineGame scheme, and run on an iPhone or Simulator."
