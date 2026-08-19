#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_SCREENSHOT_BYTES="${MIN_SCREENSHOT_BYTES:-120000}"
VERIFY_UNIQUE_THEME_FRAMES="${VERIFY_UNIQUE_THEME_FRAMES:-1}"
VERIFY_THEME_TOUR_SEMANTICS="${VERIFY_THEME_TOUR_SEMANTICS:-1}"

TOUR_DIR="${1:-${TOUR_DIR:-}}"
if [[ -z "$TOUR_DIR" || ! -d "$TOUR_DIR" ]]; then
  echo "Preview theme tour directory not found. Pass the capture directory path." >&2
  exit 1
fi

MANIFEST="$TOUR_DIR/preview-theme-tour-manifest.txt"
SUMMARY="${THEME_TOUR_VERIFY_SUMMARY_PATH:-$TOUR_DIR/preview-theme-tour-verification.txt}"
if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing Preview theme tour manifest." >&2
  exit 1
fi

SOURCE_SHA="$(awk -F= '/^source_sha=/{print $2; exit}' "$MANIFEST")"
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Theme tour manifest is not bound to an exact source SHA." >&2
  exit 1
fi

for required in \
  'themes=matrixRain midnightBlack whiteGold arcticGlass emberCore' \
  'states=forge-clean pending-approval local-ready local-missing history-proof' \
  'expected_png_count=25'; do
  if ! grep -Fq "$required" "$MANIFEST"; then
    echo "Theme tour manifest missing contract: $required" >&2
    exit 1
  fi
done

EXPECTED=(
  01-matrix-rain-forge-clean.png
  01-matrix-rain-pending-approval.png
  01-matrix-rain-local-ready.png
  01-matrix-rain-local-missing.png
  01-matrix-rain-history-proof.png
  02-midnight-black-forge-clean.png
  02-midnight-black-pending-approval.png
  02-midnight-black-local-ready.png
  02-midnight-black-local-missing.png
  02-midnight-black-history-proof.png
  03-white-gold-forge-clean.png
  03-white-gold-pending-approval.png
  03-white-gold-local-ready.png
  03-white-gold-local-missing.png
  03-white-gold-history-proof.png
  04-arctic-glass-forge-clean.png
  04-arctic-glass-pending-approval.png
  04-arctic-glass-local-ready.png
  04-arctic-glass-local-missing.png
  04-arctic-glass-history-proof.png
  05-ember-core-forge-clean.png
  05-ember-core-pending-approval.png
  05-ember-core-local-ready.png
  05-ember-core-local-missing.png
  05-ember-core-history-proof.png
)

OCR_SWIFT_SCRIPT=""
HASH_LEDGER="$(mktemp -t novaforge-theme-hashes.XXXXXX)"
cleanup() {
  rm -f "$HASH_LEDGER"
  if [[ -n "$OCR_SWIFT_SCRIPT" && -f "$OCR_SWIFT_SCRIPT" ]]; then
    rm -f "$OCR_SWIFT_SCRIPT"
  fi
}
trap cleanup EXIT

ocr_text_for_screenshot() {
  local screenshot_path="$1"
  if [[ -z "$OCR_SWIFT_SCRIPT" ]]; then
    OCR_SWIFT_SCRIPT="$(mktemp -t novaforge-theme-ocr.XXXXXX.swift)"
    cat > "$OCR_SWIFT_SCRIPT" <<'SWIFT'
import Foundation
import Vision
import AppKit

let args = CommandLine.arguments
if args.count < 2 { exit(64) }
let url = URL(fileURLWithPath: args[1])
guard let image = NSImage(contentsOf: url),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    exit(65)
}
let request = VNRecognizeTextRequest { request, error in
    if error != nil { exit(66) }
    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
    for observation in observations {
        if let text = observation.topCandidates(1).first?.string { print(text) }
    }
}
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.minimumTextHeight = 0.012
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do { try handler.perform([request]) } catch { exit(67) }
SWIFT
  fi
  xcrun swift "$OCR_SWIFT_SCRIPT" "$screenshot_path"
}

semantic_tokens_for_name() {
  case "$1" in
    *-forge-clean.png) printf '%s' 'NovaForge;Forge' ;;
    *-pending-approval.png) printf '%s' 'NovaForge;Forge' ;;
    *-local-ready.png) printf '%s' 'Control' ;;
    *-local-missing.png) printf '%s' 'Local' ;;
    *-history-proof.png) printf '%s' 'History' ;;
    *) printf '%s' '' ;;
  esac
}

assert_semantics() {
  local name="$1"
  local screenshot_path="$2"
  [[ "$VERIFY_THEME_TOUR_SEMANTICS" == "1" ]] || return 0
  local token_list
  token_list="$(semantic_tokens_for_name "$name")"
  [[ -n "$token_list" ]] || return 0

  local ocr_text
  if ! ocr_text="$(ocr_text_for_screenshot "$screenshot_path")"; then
    echo "Could not inspect semantic text for $name" >&2
    exit 1
  fi
  local lower_ocr
  lower_ocr="$(printf '%s' "$ocr_text" | tr '[:upper:]' '[:lower:]')"
  local old_ifs="$IFS"
  IFS=';'
  for token in $token_list; do
    local lower_token
    lower_token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_ocr" != *"$lower_token"* ]]; then
      echo "Theme tour screenshot failed semantic check: $name missing '$token'" >&2
      exit 1
    fi
  done
  IFS="$old_ifs"
}

{
  echo "NovaForge Preview theme tour verification"
  echo "source_sha=$SOURCE_SHA"
  echo "minimum_screenshot_bytes=$MIN_SCREENSHOT_BYTES"
  echo "unique_frame_guard=$VERIFY_UNIQUE_THEME_FRAMES"
  echo "semantic_guard=$VERIFY_THEME_TOUR_SEMANTICS"
  echo
} > "$SUMMARY"

for name in "${EXPECTED[@]}"; do
  screenshot_path="$TOUR_DIR/$name"
  if [[ ! -f "$screenshot_path" ]]; then
    echo "Missing Preview theme screenshot: $name" >&2
    exit 1
  fi

  bytes="$(wc -c < "$screenshot_path" | tr -d '[:space:]')"
  if (( bytes < MIN_SCREENSHOT_BYTES )); then
    echo "Preview theme screenshot is below ${MIN_SCREENSHOT_BYTES}B: $name (${bytes}B)" >&2
    exit 1
  fi

  image_info="$(sips -g pixelWidth -g pixelHeight "$screenshot_path" 2>/dev/null || true)"
  width="$(printf '%s\n' "$image_info" | awk '/pixelWidth:/ { print $2; exit }')"
  height="$(printf '%s\n' "$image_info" | awk '/pixelHeight:/ { print $2; exit }')"
  if [[ -z "$width" || -z "$height" || "$width" == "0" || "$height" == "0" ]]; then
    echo "Unreadable Preview theme screenshot: $name" >&2
    exit 1
  fi

  screenshot_hash="$(shasum -a 256 "$screenshot_path" | awk '{print $1}')"
  if [[ "$VERIFY_UNIQUE_THEME_FRAMES" == "1" ]] && grep -Fq "$screenshot_hash " "$HASH_LEDGER"; then
    duplicate="$(grep -F "$screenshot_hash " "$HASH_LEDGER" | head -1 | cut -d' ' -f2-)"
    echo "Duplicate Preview theme frame: $name matches $duplicate" >&2
    echo "This usually means a requested theme/state failed to render before capture." >&2
    exit 1
  fi
  printf '%s %s\n' "$screenshot_hash" "$name" >> "$HASH_LEDGER"

  assert_semantics "$name" "$screenshot_path"
  echo "$name ${bytes}B ${width}x${height} sha256=$screenshot_hash" >> "$SUMMARY"
done

ACTUAL_COUNT="$(find "$TOUR_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d '[:space:]')"
if (( ACTUAL_COUNT != 25 )); then
  echo "Preview theme screenshot count mismatch: expected 25, found $ACTUAL_COUNT" >&2
  exit 1
fi

echo "Preview five-theme tour verification passed for source $SOURCE_SHA."
echo "Summary: $SUMMARY"
echo "Image integrity/coverage passing is not visual-design acceptance by itself."
