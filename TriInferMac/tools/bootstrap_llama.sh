#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
TARGET="$VENDOR/llama.xcframework"
URL="https://github.com/ggml-org/llama.cpp/releases/download/b10456/llama-b10456-xcframework.zip"
EXPECTED="0223bedd0a01232399d943dcb72bc227882bc90df98e29d7a92343531a88cc02"
mkdir -p "$VENDOR"

if [[ -d "$TARGET" ]]; then
  MARKER="$VENDOR/.llama-release"
  if [[ -f "$MARKER" ]] && [[ "$(cat "$MARKER")" == "b10456" ]]; then
    echo "llama.xcframework b10456 already installed"
    exit 0
  fi
  rm -rf "$TARGET"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl --fail --location --retry 3 --retry-delay 2 --output "$TMP/llama.zip" "$URL"
ACTUAL="$(shasum -a 256 "$TMP/llama.zip" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "llama.cpp checksum mismatch: $ACTUAL" >&2
  exit 3
fi
unzip -q "$TMP/llama.zip" -d "$TMP/unpacked"
SOURCE="$(find "$TMP/unpacked" -type d -name 'llama.xcframework' -print -quit)"
if [[ -z "$SOURCE" ]]; then
  echo 'llama.xcframework missing from release archive' >&2
  exit 4
fi
cp -R "$SOURCE" "$TARGET"
echo 'b10456' > "$VENDOR/.llama-release"
echo "Installed llama.cpp b10456 XCFramework ($(du -sh "$TARGET" | awk '{print $1}'))"
