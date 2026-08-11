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

require_file "$composer"
require_file "$drawer"

# Composer: the five-stop effort control must remain operable without drag-only
# interaction, expose useful VoiceOver state, and suppress decorative motion.
require_literal "$composer" '@Environment(\.accessibilityReduceMotion) private var reduceMotion' \
  "Composer must observe Reduce Motion"
require_literal "$composer" '.accessibilityLabel("Reasoning effort")' \
  "reasoning effort slider must keep a VoiceOver label"
require_literal "$composer" '.accessibilityValue(selection.title)' \
  "reasoning effort slider must announce the selected level"
require_literal "$composer" '.accessibilityAdjustableAction { direction in' \
  "reasoning effort must remain VoiceOver-adjustable instead of drag-only"
require_literal "$composer" '.accessibilityIdentifier("reasoningEffortSlider")' \
  "reasoning effort slider must keep its stable accessibility identifier"
require_literal "$composer" 'withAnimation(reduceMotion ? nil : .snappy' \
  "reasoning effort changes must suppress custom motion under Reduce Motion"
require_literal "$composer" 'if reduceMotion || !AgentPerformance.allowsDecorativeMotion {' \
  "Ultra decorative ripple must have a non-animated Reduce Motion path"
require_literal "$composer" '.accessibilityHidden(true)' \
  "decorative Ultra ripple must stay hidden from accessibility"

# Composer controls: primary run/model controls must preserve semantic labels,
# stable identifiers, and the shared minimum touch target.
require_literal "$composer" '.accessibilityLabel("Stop generating")' \
  "Stop control must keep its VoiceOver action label"
require_literal "$composer" '.accessibilityIdentifier("composerStopButton")' \
  "Stop control must keep its stable accessibility identifier"
require_literal "$composer" '.accessibilityIdentifier("runProgressToggle")' \
  "run progress disclosure must keep its stable accessibility identifier"
require_literal "$composer" '.accessibilityIdentifier("composerModelNativeMenu")' \
  "model chooser must keep its stable accessibility identifier"
require_literal "$composer" 'minHeight: AgentDesign.minimumTouchTarget' \
  "Composer interactive controls must retain the shared minimum touch target"

# Reduce Transparency is an explicit Preview acceptance requirement. The
# Composer glass surface must retain an opaque/fallback path rather than only
# rendering Liquid Glass.
require_literal "$composer" '@Environment(\.accessibilityReduceTransparency) private var reduceTransparency' \
  "Composer must observe Reduce Transparency"
require_regex "$composer" 'if reduceTransparency \|\|' \
  "Composer glass must fail over when Reduce Transparency is enabled"
require_literal "$composer" 'fallback(content: content)' \
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
