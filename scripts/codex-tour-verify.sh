#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail

ROOT_DIR="${0:A:h:h}"
MIN_SCREENSHOT_BYTES="${MIN_SCREENSHOT_BYTES:-120000}"
ALLOW_EXTRA_TOUR_SCREENSHOTS="${ALLOW_EXTRA_TOUR_SCREENSHOTS:-0}"
VERIFY_UNIQUE_TOUR_SCREENSHOTS="${VERIFY_UNIQUE_TOUR_SCREENSHOTS:-1}"
VERIFY_TOUR_SEMANTICS="${VERIFY_TOUR_SEMANTICS:-1}"
VERIFY_TOUR_PROVENANCE="${VERIFY_TOUR_PROVENANCE:-1}"
OCR_TIMEOUT="${OCR_TIMEOUT:-60}"
IMAGE_INFO_TIMEOUT="${IMAGE_INFO_TIMEOUT:-20}"

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
TOUR_METADATA_PATH="${TOUR_METADATA_PATH:-$TOUR_DIR/tour-metadata.txt}"
TOUR_FIXTURE_MANIFEST_PATH="${TOUR_FIXTURE_MANIFEST_PATH:-$TOUR_DIR/tour-fixtures.tsv}"
OCR_SWIFT_SCRIPT=""

for timeout_value in "$OCR_TIMEOUT" "$IMAGE_INFO_TIMEOUT"; do
  if ! [[ "$timeout_value" =~ '^[1-9][0-9]*$' ]]; then
    echo "OCR_TIMEOUT and IMAGE_INFO_TIMEOUT must be positive integers." >&2
    exit 2
  fi
done
if [[ "$VERIFY_UNIQUE_TOUR_SCREENSHOTS" != "1" ]]; then
  echo "Unique screenshot verification cannot be disabled." >&2
  exit 2
fi
if [[ "$VERIFY_TOUR_SEMANTICS" != "1" ]]; then
  echo "Semantic OCR verification cannot be disabled." >&2
  exit 2
fi
if [[ "$VERIFY_TOUR_PROVENANCE" != "1" ]]; then
  echo "Tour provenance verification cannot be disabled." >&2
  exit 2
fi

cleanup_ocr_script() {
  if [[ -n "$OCR_SWIFT_SCRIPT" && -f "$OCR_SWIFT_SCRIPT" ]]; then
    rm -f "$OCR_SWIFT_SCRIPT"
  fi
}
trap cleanup_ocr_script EXIT

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  [[ "$timeout_seconds" =~ '^[1-9][0-9]*$' ]] || return 2
  "$@" &
  local command_pid=$!
  local elapsed=0
  while kill -0 "$command_pid" 2>/dev/null; do
    if (( elapsed >= timeout_seconds )); then
      terminate_process_tree "$command_pid" TERM
      sleep 1
      terminate_process_tree "$command_pid" KILL
      wait "$command_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$command_pid"
}

terminate_process_tree() {
  local process_pid="$1"
  local signal="$2"
  local child_pid
  local child_pids

  [[ "$process_pid" =~ '^[0-9]+$' ]] || return 0
  child_pids="$(pgrep -P "$process_pid" 2>/dev/null || true)"
  for child_pid in ${(f)child_pids}; do
    terminate_process_tree "$child_pid" "$signal"
  done
  kill -s "$signal" "$process_pid" 2>/dev/null || true
}

metadata_value() {
  local key="$1"
  awk -F '=' -v expected_key="$key" '$1 == expected_key { sub(/^[^=]*=/, ""); print; exit }' "$TOUR_METADATA_PATH"
}

source_tree_hash() {
  local commit_tree tracked_diff_hash untracked_hash diff_hash
  commit_tree="$(git -C "$ROOT_DIR" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
  [[ -n "$commit_tree" ]] || {
    print -r -- "unknown"
    return
  }
  tracked_diff_hash="$(git -C "$ROOT_DIR" diff --no-ext-diff --binary HEAD 2>/dev/null | shasum -a 256 | awk '{ print $1 }')"
  untracked_hash="$({
    # Keep app provenance stable when host-only Codex/Hermes state lives in
    # the checkout. Those directories are not NovaForge build inputs.
    git -C "$ROOT_DIR" ls-files --others --exclude-standard -z -- . \
      ':(exclude).hermes/**' ':(exclude)automation/**' 2>/dev/null |
      while IFS= read -r -d '' relative_path; do
        local file_hash
        if [[ -L "$ROOT_DIR/$relative_path" ]]; then
          file_hash="symlink:$(readlink "$ROOT_DIR/$relative_path" | shasum -a 256 | awk '{ print $1 }')"
        elif [[ -f "$ROOT_DIR/$relative_path" ]]; then
          file_hash="$(shasum -a 256 "$ROOT_DIR/$relative_path" 2>/dev/null | awk '{ print $1 }')"
        elif [[ -d "$ROOT_DIR/$relative_path" ]]; then
          file_hash="directory"
        else
          file_hash="unreadable"
        fi
        print -rn -- "$relative_path\0${file_hash:-unreadable}\0"
      done
  } | shasum -a 256 | awk '{ print $1 }')"
  diff_hash="$(print -rn -- "$tracked_diff_hash\0$untracked_hash" | shasum -a 256 | awk '{ print $1 }')"
  print -r -- "sha256:${commit_tree}:${diff_hash}"
}

app_bundle_hash() {
  local app_path="$1"
  local bundle_hash
  bundle_hash="$(find "$app_path" -type f -print0 | sort -z |
    while IFS= read -r -d '' artifact_path; do
      local artifact_hash
      artifact_hash="$(shasum -a 256 "$artifact_path" 2>/dev/null | awk '{ print $1 }')"
      print -rn -- "$artifact_path\0${artifact_hash:-unreadable}\0"
    done | shasum -a 256 | awk '{ print $1 }')"
  print -r -- "sha256:$bundle_hash"
}

verify_tour_provenance() {
  [[ -f "$TOUR_METADATA_PATH" ]] || {
    echo "Missing tour provenance metadata: $TOUR_METADATA_PATH" >&2
    exit 1
  }
  local recorded_commit="$(metadata_value sourceCommit)"
  local recorded_tree_hash="$(metadata_value sourceTreeHash)"
  local recorded_app_hash="$(metadata_value appBundleHash)"
  local recorded_surface_count="$(metadata_value expectedSurfaceCount)"
  local recorded_app_path="$(metadata_value appPath)"
  [[ "$recorded_commit" =~ '^[0-9a-fA-F]{40}$' ]] || { echo "Invalid source commit in tour metadata." >&2; exit 1; }
  [[ "$recorded_tree_hash" =~ '^sha256:[0-9a-fA-F]{40}:[0-9a-fA-F]{64}$' ]] || { echo "Invalid source tree hash in tour metadata." >&2; exit 1; }
  [[ "$recorded_app_hash" =~ '^sha256:[0-9a-fA-F]{64}$' ]] || { echo "Invalid app bundle hash in tour metadata." >&2; exit 1; }
  [[ "$recorded_surface_count" == "20" ]] || { echo "Tour metadata does not describe 20 surfaces." >&2; exit 1; }
  [[ "$recorded_tree_hash" == "$(source_tree_hash)" ]] || {
    echo "Tour source tree changed since capture." >&2
    exit 1
  }
  if [[ -d "$recorded_app_path" ]]; then
    [[ "$recorded_app_hash" == "$(app_bundle_hash "$recorded_app_path")" ]] || {
      echo "Tour app bundle changed since capture: $recorded_app_path" >&2
      exit 1
    }
  else
    echo "App bundle no longer present; retaining recorded build hash." >&2
  fi
  print -r -- "provenance ok sourceCommit=$recorded_commit sourceTreeHash=$recorded_tree_hash appBundleHash=$recorded_app_hash"
  print -r -- "provenance ok sourceCommit=$recorded_commit sourceTreeHash=$recorded_tree_hash appBundleHash=$recorded_app_hash" >> "$TOUR_VERIFY_SUMMARY_PATH"
}

expected_fixture_for() {
  case "$1" in
    01-chat-default-clean.png) print -r -- "chat-clean" ;;
    02-mission-dossier-idle.png) print -r -- "project-idle" ;;
    03-mission-dossier-running.png) print -r -- "project-running" ;;
    04-chat-pending-approval.png) print -r -- "chat-pending-approval" ;;
    05-mission-dossier-waiting.png) print -r -- "project-waiting-approval" ;;
    06-mission-dossier-blocked.png) print -r -- "project-blocked" ;;
    07-mission-dossier-proof.png) print -r -- "project-proof" ;;
    08-mission-dossier-resume.png) print -r -- "project-resume" ;;
    09-mission-dossier-auto-continue-countdown.png) print -r -- "project-auto-continue" ;;
    10-runs-proof.png) print -r -- "runs-proof" ;;
    11-files-proof.png) print -r -- "files-proof" ;;
    12-terminal-live-record.png) print -r -- "terminal-live-record" ;;
    13-settings-local-ready.png) print -r -- "settings-local-ready" ;;
    14-runs-pending-approval.png) print -r -- "runs-approval-history" ;;
    15-theme-matrix-mission-dossier-running.png) print -r -- "theme-matrix-project-running" ;;
    16-theme-midnight-chat-general.png) print -r -- "theme-midnight-chat" ;;
    17-theme-whitegold-settings.png) print -r -- "theme-whitegold-settings" ;;
    18-theme-arctic-runs-proof.png) print -r -- "theme-arctic-runs-proof" ;;
    19-theme-ember-terminal-proof.png) print -r -- "theme-ember-terminal-proof" ;;
    20-mission-dossier-intake-brief.png) print -r -- "project-intake" ;;
    *) return 1 ;;
  esac
}

verify_fixture_manifest() {
  [[ -f "$TOUR_FIXTURE_MANIFEST_PATH" ]] || {
    echo "Missing tour fixture manifest: $TOUR_FIXTURE_MANIFEST_PATH" >&2
    exit 1
  }
  local name expected_fixture actual_fixture
  for name in "${expected[@]}"; do
    expected_fixture="$(expected_fixture_for "$name")"
    actual_fixture="$(awk -F '\t' -v expected_name="$name" '$1 == expected_name { print $2; count += 1 } END { if (count != 1) exit 1 }' "$TOUR_FIXTURE_MANIFEST_PATH" || true)"
    [[ "$actual_fixture" == "$expected_fixture" ]] || {
      echo "Tour fixture mismatch for $name: expected $expected_fixture, found ${actual_fixture:-missing}." >&2
      exit 1
    }
  done
  local manifest_count
  manifest_count="$(awk -F '\t' 'NR > 1 && NF >= 2 { count += 1 } END { print count + 0 }' "$TOUR_FIXTURE_MANIFEST_PATH")"
  [[ "$manifest_count" == "20" ]] || {
    echo "Tour fixture manifest count mismatch: expected 20, found $manifest_count." >&2
    exit 1
  }
  print -r -- "fixtures ok count=$manifest_count distinct approval/chat/project/runs states"
  print -r -- "fixtures ok count=$manifest_count distinct approval/chat/project/runs states" >> "$TOUR_VERIFY_SUMMARY_PATH"
}

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
  run_with_timeout "$OCR_TIMEOUT" xcrun swift "$OCR_SWIFT_SCRIPT" "$screenshot_path"
}

assert_semantic_tokens() {
  local name="$1"
  local screenshot_path="$2"
  local token_list="$3"
  [[ -n "$token_list" ]] || return 0

  local ocr_text
  if ! ocr_text="$(ocr_text_for_screenshot "$screenshot_path")"; then
    echo "Could not OCR tour screenshot for semantic verification: $name" >&2
    exit 1
  fi

  # Vision emits each recognized line separately. Join those lines before
  # matching so a visible wrapped phrase such as "Qwen Coder Q4" is checked
  # as text rather than rejected solely because the layout inserted a break.
  local normalized_ocr="${(j: :)${(f)ocr_text}}"
  local lower_ocr="${normalized_ocr:l}"
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

expected=(
  "01-chat-default-clean.png"
  "02-mission-dossier-idle.png"
  "03-mission-dossier-running.png"
  "04-chat-pending-approval.png"
  "05-mission-dossier-waiting.png"
  "06-mission-dossier-blocked.png"
  "07-mission-dossier-proof.png"
  "08-mission-dossier-resume.png"
  "09-mission-dossier-auto-continue-countdown.png"
  "10-runs-proof.png"
  "11-files-proof.png"
  "12-terminal-live-record.png"
  "13-settings-local-ready.png"
  "14-runs-pending-approval.png"
  "15-theme-matrix-mission-dossier-running.png"
  "16-theme-midnight-chat-general.png"
  "17-theme-whitegold-settings.png"
  "18-theme-arctic-runs-proof.png"
  "19-theme-ember-terminal-proof.png"
  "20-mission-dossier-intake-brief.png"
)

typeset -A semantic_checks
semantic_checks[01-chat-default-clean.png]="NovaForge;Forge;Workspace;History;Control;Qwen Coder Q4;1.12 GB;iPhone 12;ON-DEVICE"
semantic_checks[02-mission-dossier-idle.png]="Mission;Overview;Plan;Proof;Activity"
semantic_checks[03-mission-dossier-running.png]="Running;Mission;Overview;Plan;Proof"
semantic_checks[04-chat-pending-approval.png]="Run details;Approval Queue;Approval;approval-demo.html"
semantic_checks[05-mission-dossier-waiting.png]="Approval Gate;Mission dossier;Approval required;Approval is waiting now;Approve;Reject"
semantic_checks[06-mission-dossier-blocked.png]="Blocked;Mission;Overview;Plan;Proof"
semantic_checks[07-mission-dossier-proof.png]="Proof;Mission;Overview;Activity"
semantic_checks[08-mission-dossier-resume.png]="Mission;Overview;Plan;Proof"
semantic_checks[09-mission-dossier-auto-continue-countdown.png]="Mission;Overview;Plan;Proof"
semantic_checks[10-runs-proof.png]="History;Proof Receipt;Command proof captured;Completed"
semantic_checks[11-files-proof.png]="Workspace;project-os-proof.html;Evidence"
semantic_checks[12-terminal-live-record.png]="Terminal;1;RECEIPTS;agent live terminal sync proof"
semantic_checks[13-settings-local-ready.png]="Control;Ready to run;Qwen Coder Q4;1.12 GB;Ready"
semantic_checks[14-runs-pending-approval.png]="History;Approval Gate;3/7;Approve;Reject"
semantic_checks[15-theme-matrix-mission-dossier-running.png]="Running;Mission"
semantic_checks[16-theme-midnight-chat-general.png]="NovaForge;Forge;Midnight Black;Qwen Coder Q4;READY"
semantic_checks[17-theme-whitegold-settings.png]="Control;Ready to run;Qwen Coder Q4;White Gold;Ready"
semantic_checks[18-theme-arctic-runs-proof.png]="History;Proof Receipt;Command proof captured;Completed"
semantic_checks[19-theme-ember-terminal-proof.png]="Terminal;agent live terminal sync proof"
semantic_checks[20-mission-dossier-intake-brief.png]="New Project;cozy farming roguelite;NovaForge will start with;Create"

echo "Verifying tour screenshots: $TOUR_DIR"
{
  echo "NovaForge tour verification"
  echo "Tour directory: $TOUR_DIR"
  echo "Minimum screenshot bytes: $MIN_SCREENSHOT_BYTES"
  echo "Unique screenshot guard: $VERIFY_UNIQUE_TOUR_SCREENSHOTS"
  echo "Semantic OCR guard: $VERIFY_TOUR_SEMANTICS"
  echo "Provenance guard: $VERIFY_TOUR_PROVENANCE"
  echo
} > "$TOUR_VERIFY_SUMMARY_PATH"

verify_tour_provenance
verify_fixture_manifest

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

  image_info="$(run_with_timeout "$IMAGE_INFO_TIMEOUT" sips -g pixelWidth -g pixelHeight "$screenshot_path" 2>/dev/null || true)"
  width="$(print -r -- "$image_info" | awk '/pixelWidth:/ { print $2; exit }')"
  height="$(print -r -- "$image_info" | awk '/pixelHeight:/ { print $2; exit }')"
  if [[ -z "$width" || -z "$height" || "$width" == "0" || "$height" == "0" ]]; then
    echo "Tour screenshot is not a readable image: $name" >&2
    exit 1
  fi

  screenshot_hash="$(shasum -a 256 "$screenshot_path" | awk '{ print $1 }')"
  if [[ -n "${screenshot_hashes[$screenshot_hash]-}" ]]; then
    duplicate_screenshots+=("$name duplicates ${screenshot_hashes[$screenshot_hash]}")
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

if (( ${#duplicate_screenshots[@]} > 0 )); then
  echo "Tour screenshots repeated; the app may not have reached every requested surface:" >&2
  for duplicate in "${duplicate_screenshots[@]}"; do
    echo "  $duplicate" >&2
  done
  echo "Every surface must produce a distinct screenshot; fix the fixture or launch routing." >&2
  exit 1
fi

echo "Tour verification passed."
echo "Summary: $TOUR_VERIFY_SUMMARY_PATH"
