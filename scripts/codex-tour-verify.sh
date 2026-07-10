#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail

ROOT_DIR="${0:A:h:h}"
MIN_SCREENSHOT_BYTES="${MIN_SCREENSHOT_BYTES:-120000}"
ALLOW_EXTRA_TOUR_SCREENSHOTS="${ALLOW_EXTRA_TOUR_SCREENSHOTS:-0}"
VERIFY_UNIQUE_TOUR_SCREENSHOTS="${VERIFY_UNIQUE_TOUR_SCREENSHOTS:-1}"
TOUR_MANIFEST_CHECK="${TOUR_MANIFEST_CHECK:-0}"
TOUR_SCRIPT="${TOUR_SCRIPT:-$ROOT_DIR/scripts/codex-sim-tour.sh}"
VERIFY_TOUR_SEMANTICS="${VERIFY_TOUR_SEMANTICS:-1}"

expected=(
  "01-chat-default-clean.png"
  "02-mission-dossier-idle.png"
  "03-mission-dossier-running.png"
  "04-mission-dossier-approval.png"
  "05-mission-dossier-waiting.png"
  "06-mission-dossier-blocked.png"
  "07-mission-dossier-proof.png"
  "08-mission-dossier-resume.png"
  "09-mission-dossier-auto-continue-countdown.png"
  "10-runs-proof.png"
  "11-files-proof.png"
  "12-terminal-live-record.png"
  "13-settings-local-ready.png"
  "14-chat-pending-approval.png"
  "15-theme-matrix-mission-dossier-running.png"
  "16-theme-midnight-chat-general.png"
  "17-theme-whitegold-settings.png"
  "18-theme-arctic-runs-proof.png"
  "19-theme-ember-terminal-proof.png"
  "20-mission-dossier-intake-brief.png"
)

check_tour_manifest() {
  local runner_names
  local verifier_names
  runner_names="$(grep -E 'run_step "[0-9]{2}-[^" ]+"' "$TOUR_SCRIPT" | sed -E 's/.*run_step "([0-9]{2}-[^"]+)".*/\1.png/')"
  verifier_names="$(printf '%s\n' "${expected[@]}")"

  local mismatch=0
  local missing
  missing="$(comm -23 <(printf '%s\n' "$runner_names" | sort) <(printf '%s\n' "$verifier_names" | sort))"
  if [[ -n "$missing" ]]; then
    echo "Tour verifier is missing runner frames:" >&2
    print -r -- "$missing" >&2
    mismatch=1
  fi

  local extra
  extra="$(comm -13 <(printf '%s\n' "$runner_names" | sort) <(printf '%s\n' "$verifier_names" | sort))"
  if [[ -n "$extra" ]]; then
    echo "Tour verifier expects frames not produced by runner:" >&2
    print -r -- "$extra" >&2
    mismatch=1
  fi

  if (( mismatch != 0 )); then
    exit 1
  fi

  echo "Tour manifest check passed (${#expected[@]} frames)."
}

if [[ "$TOUR_MANIFEST_CHECK" == "1" ]]; then
  check_tour_manifest
  exit 0
fi

TOUR_DIR="${1:-${TOUR_DIR:-}}"
if [[ -z "$TOUR_DIR" ]]; then
  latest=("$ROOT_DIR"/NovaForgeScreenshots/codex-tour-*(/Nom[1]))
  if (( ${#latest} > 0 )); then
    TOUR_DIR="$latest[1]"
  fi
fi

if [[ -z "$TOUR_DIR" || ! -d "$TOUR_DIR" ]]; then
  echo "Tour directory not found. Pass TOUR_DIR or a directory path." >&2
  exit 1
fi

TOUR_VERIFY_SUMMARY_PATH="${TOUR_VERIFY_SUMMARY_PATH:-$TOUR_DIR/tour-verification-summary.txt}"
OCR_SWIFT_SCRIPT=""

cleanup_ocr_script() {
  if [[ -n "$OCR_SWIFT_SCRIPT" && -f "$OCR_SWIFT_SCRIPT" ]]; then
    rm -f "$OCR_SWIFT_SCRIPT"
  fi
}
trap cleanup_ocr_script EXIT

ocr_text_for_screenshot() {
  local screenshot_path="$1"
  if [[ -z "$OCR_SWIFT_SCRIPT" ]]; then
    OCR_SWIFT_SCRIPT="$(mktemp -t novaforge-tour-ocr.XXXXXX.swift)"
    cat > "$OCR_SWIFT_SCRIPT" <<'SWIFT'
import Foundation
import Vision
import AppKit

let args = CommandLine.arguments
if args.count < 2 {
    fputs("usage: ocr <image>\n", stderr)
    exit(64)
}
let url = URL(fileURLWithPath: args[1])
guard let image = NSImage(contentsOf: url),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Could not read image: \(args[1])\n", stderr)
    exit(65)
}
let request = VNRecognizeTextRequest { request, error in
    if let error {
        fputs("OCR failed: \(error.localizedDescription)\n", stderr)
        exit(66)
    }
    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
    for observation in observations {
        if let text = observation.topCandidates(1).first?.string {
            print(text)
        }
    }
}
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.minimumTextHeight = 0.012
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([request])
} catch {
    fputs("OCR perform failed: \(error.localizedDescription)\n", stderr)
    exit(67)
}
SWIFT
  fi
  xcrun swift "$OCR_SWIFT_SCRIPT" "$screenshot_path"
}

assert_semantic_tokens() {
  local name="$1"
  local screenshot_path="$2"
  local token_list="$3"
  [[ "$VERIFY_TOUR_SEMANTICS" == "1" ]] || return 0
  [[ -n "$token_list" ]] || return 0

  local ocr_text
  if ! ocr_text="$(ocr_text_for_screenshot "$screenshot_path")"; then
    echo "Could not OCR tour screenshot for semantic verification: $name" >&2
    exit 1
  fi

  local lower_ocr="${ocr_text:l}"
  local token
  for token in ${(s:;:)token_list}; do
    token="${token##[[:space:]]}"
    token="${token%%[[:space:]]}"
    [[ -n "$token" ]] || continue
    if [[ "$lower_ocr" != *"${token:l}"* ]]; then
      echo "Tour screenshot failed semantic check: $name" >&2
      echo "Missing OCR token: $token" >&2
      echo "OCR excerpt:" >&2
      print -r -- "$ocr_text" | head -40 >&2
      exit 1
    fi
  done

  echo "semantic ok $name tokens=$token_list"
  echo "semantic ok $name tokens=$token_list" >> "$TOUR_VERIFY_SUMMARY_PATH"
}

typeset -A semantic_checks
semantic_checks["01-chat-default-clean.png"]="NovaForge;Forge;Workspace;History;Control"
semantic_checks["02-mission-dossier-idle.png"]="Mission;Overview;Plan;Proof;Activity"
semantic_checks["03-mission-dossier-running.png"]="Running;Mission;Overview;Plan;Proof"
semantic_checks["04-mission-dossier-approval.png"]="Mission;Overview;Plan;Proof"
semantic_checks["05-mission-dossier-waiting.png"]="Mission;Overview;Plan;Proof"
semantic_checks["06-mission-dossier-blocked.png"]="Blocked;Mission;Overview;Plan;Proof"
semantic_checks["07-mission-dossier-proof.png"]="Proof;Mission;Overview;Activity"
semantic_checks["08-mission-dossier-resume.png"]="Mission;Overview;Plan;Proof"
semantic_checks["09-mission-dossier-auto-continue-countdown.png"]="Mission;Overview;Plan;Proof"
semantic_checks["10-runs-proof.png"]="History"
semantic_checks["11-files-proof.png"]="Workspace"
semantic_checks["12-terminal-live-record.png"]="Terminal"
semantic_checks["13-settings-local-ready.png"]="Control"
semantic_checks["14-chat-pending-approval.png"]="NovaForge;Forge"
semantic_checks["15-theme-matrix-mission-dossier-running.png"]="Running;Mission"
semantic_checks["16-theme-midnight-chat-general.png"]="NovaForge;Forge"
semantic_checks["17-theme-whitegold-settings.png"]="Control"
semantic_checks["18-theme-arctic-runs-proof.png"]="History"
semantic_checks["19-theme-ember-terminal-proof.png"]="Terminal"
semantic_checks["20-mission-dossier-intake-brief.png"]="Project;Create"

echo "Verifying tour screenshots: $TOUR_DIR"
{
  echo "NovaForge tour verification"
  echo "Tour directory: $TOUR_DIR"
  echo "Minimum screenshot bytes: $MIN_SCREENSHOT_BYTES"
  echo "Unique screenshot guard: $VERIFY_UNIQUE_TOUR_SCREENSHOTS"
  echo "Semantic OCR guard: $VERIFY_TOUR_SEMANTICS"
  echo
} > "$TOUR_VERIFY_SUMMARY_PATH"

typeset -A screenshot_hashes
duplicate_screenshots=()

for name in "${expected[@]}"; do
  screenshot_path="$TOUR_DIR/$name"
  if [[ ! -f "$screenshot_path" ]]; then
    echo "Missing tour screenshot: $name" >&2
    exit 1
  fi

  bytes="$(wc -c < "$screenshot_path" | tr -d '[:space:]')"
  if (( bytes < MIN_SCREENSHOT_BYTES )); then
    echo "Tour screenshot is below ${MIN_SCREENSHOT_BYTES}B: $name (${bytes}B)" >&2
    exit 1
  fi

  image_info="$(sips -g pixelWidth -g pixelHeight "$screenshot_path" 2>/dev/null || true)"
  width="$(print -r -- "$image_info" | awk '/pixelWidth:/ { print $2; exit }')"
  height="$(print -r -- "$image_info" | awk '/pixelHeight:/ { print $2; exit }')"
  if [[ -z "$width" || -z "$height" || "$width" == "0" || "$height" == "0" ]]; then
    echo "Tour screenshot is not a readable image: $name" >&2
    exit 1
  fi

  screenshot_hash="$(shasum -a 256 "$screenshot_path" | awk '{ print $1 }')"
  if [[ -n "${screenshot_hashes[$screenshot_hash]-}" ]]; then
    previous_name="${screenshot_hashes[$screenshot_hash]}"
    if [[ "$previous_name" == "04-mission-dossier-approval.png" && "$name" == "05-mission-dossier-waiting.png" ]]; then
      echo "ok $name intentionally repeats $previous_name"
    else
      duplicate_screenshots+=("$name duplicates $previous_name")
    fi
  else
    screenshot_hashes[$screenshot_hash]="$name"
  fi

  echo "ok $name ${bytes}B ${width}x${height} sha256=$screenshot_hash"
  echo "$name ${bytes}B ${width}x${height} sha256=$screenshot_hash" >> "$TOUR_VERIFY_SUMMARY_PATH"
  assert_semantic_tokens "$name" "$screenshot_path" "${semantic_checks[$name]-}"
done

if [[ "$ALLOW_EXTRA_TOUR_SCREENSHOTS" != "1" ]]; then
  actual_count="$(find "$TOUR_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d '[:space:]')"
  expected_count="${#expected[@]}"
  if (( actual_count != expected_count )); then
    echo "Tour screenshot count mismatch: expected $expected_count, found $actual_count." >&2
    echo "Set ALLOW_EXTRA_TOUR_SCREENSHOTS=1 to allow extra PNGs." >&2
    exit 1
  fi
fi

if [[ "$VERIFY_UNIQUE_TOUR_SCREENSHOTS" == "1" && ${#duplicate_screenshots[@]} -gt 0 ]]; then
  echo "Tour screenshots repeated; the app may not have reached every requested surface:" >&2
  for duplicate in "${duplicate_screenshots[@]}"; do
    echo "  $duplicate" >&2
  done
  echo "Set VERIFY_UNIQUE_TOUR_SCREENSHOTS=0 only when intentionally verifying duplicate frames." >&2
  exit 1
fi

echo "Tour verification passed."
echo "Summary: $TOUR_VERIFY_SUMMARY_PATH"
