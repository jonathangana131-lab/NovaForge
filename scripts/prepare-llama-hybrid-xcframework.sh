#!/bin/zsh
set -euo pipefail

# The implementation-date llama.cpp xcframework is iOS-device only because
# Xcode 27 no longer runs on Intel Macs. NovaForge's development Mac is Intel,
# so keep b6102 solely for the x86_64 simulator slice while shipping b10630 on
# physical iOS. Both upstream archives are checksum pinned before composition.

repo_root="${0:A:h:h}"
artifact_root="$repo_root/Vendor/swift-llama-cpp/Artifacts"
destination="$artifact_root/llama-hybrid.xcframework"
staging="$(mktemp -d /tmp/novaforge-llama-hybrid.XXXXXX)"
timeout_runner="$repo_root/scripts/codex-timeout-runner.pl"
trap 'rm -rf -- "$staging"' EXIT

modern_tag="b10630"
modern_sha="8dc244a161eb555e29a5427e7a2616a12d95e55a37fbdefdeede8230c3d21431"
legacy_tag="b6102"
legacy_sha="257b8ffbdda68b377e1b75cd23055b201b0e9a24e18d5a42f2960456776eab8a"

download_and_verify() {
  local tag="$1"
  local expected="$2"
  local archive="$staging/$tag.zip"
  TIMEOUT_RUNNER_LABEL="llama-download-$tag" \
    "$timeout_runner" 300 "$staging/$tag-download.log" \
    curl -fL --retry 3 --retry-max-time 240 --connect-timeout 20 --max-time 270 \
      "https://github.com/ggml-org/llama.cpp/releases/download/$tag/llama-$tag-xcframework.zip" \
      -o "$archive"
  local observed
  observed="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$observed" != "$expected" ]]; then
    print -u2 "Checksum mismatch for $tag: expected $expected, observed $observed"
    exit 1
  fi
  mkdir -p "$staging/$tag"
  TIMEOUT_RUNNER_LABEL="llama-expand-$tag" \
    "$timeout_runner" 120 "$staging/$tag-expand.log" \
    ditto -x -k "$archive" "$staging/$tag"
}

download_and_verify "$modern_tag" "$modern_sha"
download_and_verify "$legacy_tag" "$legacy_sha"

modern_xcframework="$(find "$staging/$modern_tag" -type d -name llama.xcframework -print -quit)"
legacy_xcframework="$(find "$staging/$legacy_tag" -type d -name llama.xcframework -print -quit)"
if [[ -z "$modern_xcframework" || -z "$legacy_xcframework" ]]; then
  print -u2 "An upstream archive did not contain llama.xcframework"
  exit 1
fi

mkdir -p "$artifact_root"
if [[ -e "$destination" ]]; then
  backup="$artifact_root/llama-hybrid.previous.$(date +%Y%m%d%H%M%S).xcframework"
  mv "$destination" "$backup"
fi
ditto "$modern_xcframework" "$destination"
ditto \
  "$legacy_xcframework/ios-arm64_x86_64-simulator" \
  "$destination/ios-arm64_x86_64-simulator"

plist="$destination/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :AvailableLibraries:2 dict' "$plist"
/usr/libexec/PlistBuddy -c 'Add :AvailableLibraries:2:BinaryPath string llama.framework/llama' "$plist"
/usr/libexec/PlistBuddy -c 'Add :AvailableLibraries:2:LibraryIdentifier string ios-arm64_x86_64-simulator' "$plist"
/usr/libexec/PlistBuddy -c 'Add :AvailableLibraries:2:LibraryPath string llama.framework' "$plist"
/usr/libexec/PlistBuddy -c 'Add :AvailableLibraries:2:SupportedArchitectures array' "$plist"
/usr/libexec/PlistBuddy -c 'Add :AvailableLibraries:2:SupportedArchitectures:0 string arm64' "$plist"
/usr/libexec/PlistBuddy -c 'Add :AvailableLibraries:2:SupportedArchitectures:1 string x86_64' "$plist"
/usr/libexec/PlistBuddy -c 'Add :AvailableLibraries:2:SupportedPlatform string ios' "$plist"
/usr/libexec/PlistBuddy -c 'Add :AvailableLibraries:2:SupportedPlatformVariant string simulator' "$plist"
# Debug symbols are optional XCFramework metadata. The pinned upstream
# archives do not consistently ship their declared dSYMs, and Xcode rejects a
# missing DebugSymbolsPath before compilation. Do not advertise artifacts that
# are absent from this reproducible hybrid bundle.
for library_index in 0 1 2; do
  /usr/libexec/PlistBuddy \
    -c "Delete :AvailableLibraries:${library_index}:DebugSymbolsPath" \
    "$plist" >/dev/null 2>&1 || true
done
plutil -lint "$plist"

print "Prepared $destination"
