#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
TARGET="$VENDOR/llama.xcframework"
URL="https://github.com/ggml-org/llama.cpp/releases/download/b10453/llama-b10453-xcframework.zip"
EXPECTED="c47fb6013e886307a7a0a993a1e6c02ce9a46ba0ef5be01f3eb086a13a61ea6a"
mkdir -p "$VENDOR"
if [[ -d "$TARGET" ]]; then echo "llama.xcframework already installed"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl --fail --location --retry 3 --output "$TMP/llama.zip" "$URL"
ACTUAL="$(shasum -a 256 "$TMP/llama.zip" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then echo "llama.cpp checksum mismatch: $ACTUAL" >&2; exit 3; fi
unzip -q "$TMP/llama.zip" -d "$TMP/unpacked"
SOURCE="$(find "$TMP/unpacked" -type d -name 'llama.xcframework' -print -quit)"
if [[ -z "$SOURCE" ]]; then echo 'llama.xcframework missing from release archive' >&2; exit 4; fi
cp -R "$SOURCE" "$TARGET"
echo "Installed llama.xcframework ($(du -sh "$TARGET" | awk '{print $1}'))"
