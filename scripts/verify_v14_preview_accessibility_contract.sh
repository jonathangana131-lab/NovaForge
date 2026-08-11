#!/usr/bin/env bash
set -euo pipefail

root="."
if [[ "${1:-}" == "--root" ]]; then
  root="${2:?--root requires a repository path}"
  shift 2
fi
if [[ $# -ne 0 ]]; then
  echo "usage: $0 [--root <repo>]" >&2
  exit 2
fi

composer="$root/AgentPad/Views/ChatComposer.swift"
drawer="$root/AgentPad/Views/ChatDrawerView.swift"

fail() {
  echo "V14 Preview accessibility contract failed: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing required source: ${1#$root/}"
}

require_literal() {
  local file="$1"
  local needle="$2"
  local message="$3"
  grep -Fq -- "$needle" "$file" || fail "$message"
}

require_regex() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  grep -Eq -- "$pattern" "$file" || fail "$message"
}

section_text() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  awk -v start_marker="$start_marker" -v end_marker="$end_marker" '
    index($0, start_marker) { inside = 1 }
    inside { print }
    inside && index($0, end_marker) && !index($0, start_marker) { exit }
  ' "$file"
}

require_section_literal() {
  local file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local needle="$4"
  local message="$5"
  local section
  section="$(section_text "$file" "$start_marker" "$end_marker")"
  [[ -n "$section" ]] || fail "$message (section missing)"
  grep -Fq -- "$needle" <<<"$section" || fail "$message"
}

require_file "$composer"
require_file "$drawer"

# Composer reasoning: the five-stop effort control must remain operable without
# drag-only interaction, expose useful VoiceOver state, and suppress motion.
require_section_literal "$composer" \
  'private struct ComposerReasoningPicker: View {' \
  'private struct UltraCodePowerRipple: View {' \
  '@Environment(\.accessibilityReduceMotion) private var reduceMotion' \
  "reasoning picker must observe Reduce Motion"
require_section_literal "$composer" \
  'private struct ComposerReasoningPicker: View {' \
  'private struct UltraCodePowerRipple: View {' \
  '.accessibilityLabel("Reasoning effort")' \
  "reasoning effort slider must keep a VoiceOver label"
require_section_literal "$composer" \
  'private struct ComposerReasoningPicker: View {' \
  'private struct UltraCodePowerRipple: View {' \
  '.accessibilityValue(selection.title)' \
  "reasoning effort slider must announce the selected level"
require_section_literal "$composer" \
  'private struct ComposerReasoningPicker: View {' \
  'private struct UltraCodePowerRipple: View {' \
  '.accessibilityAdjustableAction { direction in' \
  "reasoning effort must remain VoiceOver-adjustable instead of drag-only"
require_section_literal "$composer" \
  'private struct ComposerReasoningPicker: View {' \
  'private struct UltraCodePowerRipple: View {' \
  '.accessibilityIdentifier("reasoningEffortSlider")' \
  "reasoning effort slider must keep its stable accessibility identifier"
require_section_literal "$composer" \
  'private struct ComposerReasoningPicker: View {' \
  'private struct UltraCodePowerRipple: View {' \
  'withAnimation(reduceMotion ? nil : .snappy' \
  "reasoning effort changes must suppress custom motion under Reduce Motion"

# Ultra animation is decorative. Check its own struct so an unrelated hidden
# view cannot mask a regression here.
require_section_literal "$composer" \
  'private struct UltraCodePowerRipple: View {' \
  'struct AgentOrchestrationStatusCard: View {' \
  '@Environment(\.accessibilityReduceMotion) private var reduceMotion' \
  "Ultra decorative ripple must observe Reduce Motion"
require_section_literal "$composer" \
  'private struct UltraCodePowerRipple: View {' \
  'struct AgentOrchestrationStatusCard: View {' \
  'if reduceMotion || !AgentPerformance.allowsDecorativeMotion {' \
  "Ultra decorative ripple must have a non-animated Reduce Motion path"
require_section_literal "$composer" \
  'private struct UltraCodePowerRipple: View {' \
  'struct AgentOrchestrationStatusCard: View {' \
  '.accessibilityHidden(true)' \
  "decorative Ultra ripple must stay hidden from accessibility"

# Live-run rail: Stop and progress controls must preserve semantics and touch
# sizing inside the rail itself, not elsewhere in the file.
require_section_literal "$composer" \
  'struct ComposerLiveRunRail: View {' \
  'struct ComposerChromeStyle: Equatable {' \
  '.accessibilityLabel("Stop generating")' \
  "Stop control must keep its VoiceOver action label"
require_section_literal "$composer" \
  'struct ComposerLiveRunRail: View {' \
  'struct ComposerChromeStyle: Equatable {' \
  '.accessibilityIdentifier("composerStopButton")' \
  "Stop control must keep its stable accessibility identifier"
require_section_literal "$composer" \
  'struct ComposerLiveRunRail: View {' \
  'struct ComposerChromeStyle: Equatable {' \
  '.accessibilityIdentifier("runProgressToggle")' \
  "run progress disclosure must keep its stable accessibility identifier"
require_section_literal "$composer" \
  'struct ComposerLiveRunRail: View {' \
  'struct ComposerChromeStyle: Equatable {' \
  'minHeight: AgentDesign.minimumTouchTarget' \
  "live-run controls must retain the shared minimum touch target"

# Model chooser must remain a semantic, touch-sized control.
require_section_literal "$composer" \
  'struct ComposerModelMenu: View {' \
  'private struct ComposerModelChooserSheet: View {' \
  '.accessibilityIdentifier("composerModelNativeMenu")' \
  "model chooser must keep its stable accessibility identifier"
require_section_literal "$composer" \
  'struct ComposerModelMenu: View {' \
  'private struct ComposerModelChooserSheet: View {' \
  'height: AgentDesign.minimumTouchTarget' \
  "model chooser must retain the shared minimum touch target"

# Reduce Transparency is an explicit Preview acceptance requirement. Check the
# glass modifier itself so another fallback call cannot satisfy the contract.
require_section_literal "$composer" \
  'struct ComposerGlassSurfaceModifier: ViewModifier {' \
  'extension View {' \
  '@Environment(\.accessibilityReduceTransparency) private var reduceTransparency' \
  "Composer glass must observe Reduce Transparency"
require_section_literal "$composer" \
  'struct ComposerGlassSurfaceModifier: ViewModifier {' \
  'extension View {' \
  'if reduceTransparency ||' \
  "Composer glass must fail over when Reduce Transparency is enabled"
require_section_literal "$composer" \
  'struct ComposerGlassSurfaceModifier: ViewModifier {' \
  'extension View {' \
  'fallback(content: content)' \
  "Composer glass must retain an opaque fallback renderer"

# Chat drawer: core navigation has to remain discoverable by VoiceOver/XCUI,
# meet touch targets, and avoid forced slide animation under Reduce Motion.
require_literal "$drawer" '@Environment(\.accessibilityReduceMotion) private var reduceMotion' \
  "Chat drawer must observe Reduce Motion"
require_literal "$drawer" '.accessibilityLabel("Close chats")' \
  "Chat drawer close control must keep its VoiceOver label"
require_literal "$drawer" '.accessibilityIdentifier("chatDrawerClose")' \
  "Chat drawer close control must keep its stable accessibility identifier"
require_literal "$drawer" '.accessibilityLabel("New General chat")' \
  "New Chat control must keep its explicit VoiceOver label"
require_literal "$drawer" '.accessibilityHint("Creates a chat in the General workspace")' \
  "New Chat control must keep its scope hint"
require_literal "$drawer" '.accessibilityIdentifier("chatDrawerNewChat")' \
  "New Chat control must keep its stable accessibility identifier"
require_literal "$drawer" '.accessibilityLabel("Search General and project chats")' \
  "chat search must keep its scope-aware VoiceOver label"
require_literal "$drawer" '.accessibilityIdentifier("chatSearch")' \
  "chat search must keep its stable accessibility identifier"
require_literal "$drawer" '.accessibilityLabel("Current chat scope")' \
  "current scope must remain a single meaningful accessibility element"
require_literal "$drawer" '.accessibilityIdentifier("chatDrawerCurrentScope")' \
  "current scope must keep its stable accessibility identifier"
require_literal "$drawer" '.frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)' \
  "drawer icon controls must retain the shared minimum touch target"
require_literal "$drawer" 'withAnimation(reduceMotion ? nil : .smooth' \
  "drawer entrance must suppress custom motion under Reduce Motion"
require_literal "$drawer" 'withAnimation(reduceMotion ? nil : .easeOut' \
  "drawer dismissal must suppress custom motion under Reduce Motion"

echo "V14 Preview accessibility contract: PASS"
