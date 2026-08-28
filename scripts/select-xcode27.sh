#!/usr/bin/env bash

# Source this helper before any iOS 27 device command. It honors an explicit
# DEVELOPER_DIR, supports side-by-side Xcode installs, and fails closed rather
# than silently using an older xcrun/device-support stack.

novaforge_xcode27_fail() {
  echo "Xcode 27 toolchain unavailable: $1" >&2
  return 2 2>/dev/null || exit 2
}

novaforge_xcode27_check() {
  local developer_dir="$1"
  local xcodebuild_path="$developer_dir/usr/bin/xcodebuild"
  local xcode_version major sdk_version sdk_major

  [[ -x "$xcodebuild_path" ]] || return 1
  xcode_version="$($xcodebuild_path -version 2>/dev/null)" || return 1
  major="$(awk '/^Xcode / { split($2, version, "."); print version[1]; exit }' <<< "$xcode_version")"
  [[ "$major" == "27" ]] || return 1
  sdk_version="$(DEVELOPER_DIR="$developer_dir" xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)" || return 1
  sdk_major="${sdk_version%%.*}"
  [[ "$sdk_major" == "27" ]] || return 1

  export DEVELOPER_DIR="$developer_dir"
  export NOVAFORGE_XCODE_VERSION="$(head -n 1 <<< "$xcode_version")"
  export NOVAFORGE_IPHONEOS_SDK_VERSION="$sdk_version"
  return 0
}

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  novaforge_xcode27_check "$DEVELOPER_DIR" ||
    novaforge_xcode27_fail "explicit DEVELOPER_DIR is not an Xcode 27 developer directory with the iOS 27 SDK: $DEVELOPER_DIR"
else
  novaforge_xcode27_candidates=()
  [[ -n "${XCODE_27_DEVELOPER_DIR:-}" ]] &&
    novaforge_xcode27_candidates+=("$XCODE_27_DEVELOPER_DIR")
  [[ -n "${XCODE_27_APP:-}" ]] &&
    novaforge_xcode27_candidates+=("${XCODE_27_APP%/}/Contents/Developer")
  for novaforge_xcode27_app in \
    /Applications/Xcode_27*.app \
    /Applications/Xcode-27*.app \
    /Applications/Xcode.app; do
    [[ -d "$novaforge_xcode27_app" ]] || continue
    novaforge_xcode27_candidates+=("$novaforge_xcode27_app/Contents/Developer")
  done

  novaforge_xcode27_selected=""
  for novaforge_xcode27_candidate in "${novaforge_xcode27_candidates[@]}"; do
    if novaforge_xcode27_check "$novaforge_xcode27_candidate"; then
      novaforge_xcode27_selected="$novaforge_xcode27_candidate"
      break
    fi
  done
  [[ -n "$novaforge_xcode27_selected" ]] ||
    novaforge_xcode27_fail "no side-by-side Xcode 27 installation with the iOS 27 SDK was found; set XCODE_27_APP or DEVELOPER_DIR"
fi

printf 'Selected %s (%s SDK, DEVELOPER_DIR=%s)\n' \
  "$NOVAFORGE_XCODE_VERSION" "$NOVAFORGE_IPHONEOS_SDK_VERSION" "$DEVELOPER_DIR"
