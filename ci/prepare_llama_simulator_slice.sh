#!/bin/bash
# Upstream llama.cpp b10472 intentionally ships a compact release XCFramework
# without an iOS Simulator slice. Production iPhone builds must keep using that
# official immutable binary, while simulator QA needs a compatible slice.
# Build the missing slice from the exact same upstream tag and combine it only
# inside DerivedData. No generated binary is committed or shipped to devices.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DERIVED_DATA_PATH=${1:?usage: prepare_llama_simulator_slice.sh DERIVED_DATA_PATH}
LLAMA_VERSION="b10472"
PROJECT_PATH="$ROOT_DIR/AgentPad.xcodeproj"
SCHEME="AgentPad"
WORK_ROOT="$ROOT_DIR/artifacts/llama-simulator-$LLAMA_VERSION"
SOURCE_DIR="$WORK_ROOT/source"
PATCHED_XCFRAMEWORK="$WORK_ROOT/llama-patched.xcframework"

mkdir -p "$DERIVED_DATA_PATH" "$WORK_ROOT"

echo "==> Resolving official $LLAMA_VERSION package artifact into DerivedData"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -resolvePackageDependencies \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -skipPackageUpdates \
  -skipPackagePluginValidation \
  -skipMacroValidation >/dev/null

OFFICIAL_XCFRAMEWORK=$(find "$DERIVED_DATA_PATH/SourcePackages/artifacts" \
  -type d -path '*/llama/llama.xcframework' -print | head -n 1 || true)
if [[ -z "$OFFICIAL_XCFRAMEWORK" || ! -f "$OFFICIAL_XCFRAMEWORK/Info.plist" ]]; then
  echo "Resolved official llama.xcframework was not found under $DERIVED_DATA_PATH/SourcePackages/artifacts" >&2
  find "$DERIVED_DATA_PATH/SourcePackages" -maxdepth 8 -name 'llama.xcframework' -print >&2 || true
  exit 69
fi

if python3 - "$OFFICIAL_XCFRAMEWORK" <<'PY'
import plistlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
with (root / 'Info.plist').open('rb') as fh:
    libs = plistlib.load(fh).get('AvailableLibraries', [])
raise SystemExit(0 if any(x.get('SupportedPlatform') == 'ios' and x.get('SupportedPlatformVariant') == 'simulator' for x in libs) else 1)
PY
then
  echo "Official $LLAMA_VERSION artifact already contains a simulator slice; no synthesis needed."
  exit 0
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is required to synthesize the exact-tag simulator framework." >&2
  exit 69
fi

rm -rf "$SOURCE_DIR" "$PATCHED_XCFRAMEWORK"
echo "==> Checking out exact upstream llama.cpp tag $LLAMA_VERSION"
git clone --filter=blob:none --depth 1 --branch "$LLAMA_VERSION" \
  https://github.com/ggml-org/llama.cpp.git "$SOURCE_DIR" >/dev/null
UPSTREAM_SHA=$(git -C "$SOURCE_DIR" rev-parse HEAD)
TAG_SHA=$(git -C "$SOURCE_DIR" rev-list -n 1 "$LLAMA_VERSION")
[[ "$UPSTREAM_SHA" == "$TAG_SHA" ]] || {
  echo "Exact-tag provenance mismatch: checkout=$UPSTREAM_SHA tag=$TAG_SHA" >&2
  exit 70
}

echo "==> Building exact $LLAMA_VERSION iOS Simulator framework"
(
  cd "$SOURCE_DIR"
  ./build-xcframework.sh ios-sim
)
SIM_XCFRAMEWORK="$SOURCE_DIR/build-apple/llama.xcframework"
[[ -f "$SIM_XCFRAMEWORK/Info.plist" ]] || {
  echo "Upstream ios-sim build did not produce llama.xcframework" >&2
  exit 70
}

# macOS still ships Bash 3.x in some environments, so avoid mapfile/readarray.
OFFICIAL_FRAMEWORKS=()
while IFS= read -r framework; do
  [[ -n "$framework" ]] && OFFICIAL_FRAMEWORKS+=("$framework")
done < <(python3 - "$OFFICIAL_XCFRAMEWORK" <<'PY'
import plistlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
with (root / 'Info.plist').open('rb') as fh:
    data = plistlib.load(fh)
for item in data.get('AvailableLibraries', []):
    identifier = item['LibraryIdentifier']
    library_path = item['LibraryPath']
    path = root / identifier / library_path
    if not path.exists():
        raise SystemExit(f'missing official framework: {path}')
    print(path)
PY
)

SIM_FRAMEWORKS=()
while IFS= read -r framework; do
  [[ -n "$framework" ]] && SIM_FRAMEWORKS+=("$framework")
done < <(python3 - "$SIM_XCFRAMEWORK" <<'PY'
import plistlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
with (root / 'Info.plist').open('rb') as fh:
    data = plistlib.load(fh)
seen = 0
for item in data.get('AvailableLibraries', []):
    if item.get('SupportedPlatform') != 'ios' or item.get('SupportedPlatformVariant') != 'simulator':
        continue
    identifier = item['LibraryIdentifier']
    library_path = item['LibraryPath']
    path = root / identifier / library_path
    if not path.exists():
        raise SystemExit(f'missing synthesized simulator framework: {path}')
    print(path)
    seen += 1
if seen != 1:
    raise SystemExit(f'expected exactly one iOS simulator library, found {seen}')
PY
)

(( ${#OFFICIAL_FRAMEWORKS[@]} > 0 )) || { echo "Official XCFramework contained no libraries" >&2; exit 70; }
(( ${#SIM_FRAMEWORKS[@]} == 1 )) || { echo "Synthesized XCFramework did not contain exactly one simulator library" >&2; exit 70; }

CREATE_ARGS=()
for framework in "${OFFICIAL_FRAMEWORKS[@]}"; do
  CREATE_ARGS+=( -framework "$framework" )
done
for framework in "${SIM_FRAMEWORKS[@]}"; do
  CREATE_ARGS+=( -framework "$framework" )
done

echo "==> Combining official device/macOS slices with exact-tag simulator slice"
xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "$PATCHED_XCFRAMEWORK" >/dev/null

python3 - "$PATCHED_XCFRAMEWORK" "$LLAMA_VERSION" "$UPSTREAM_SHA" <<'PY'
import plistlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
version, sha = sys.argv[2:]
with (root / 'Info.plist').open('rb') as fh:
    data = plistlib.load(fh)
libs = data.get('AvailableLibraries', [])
assert any(x.get('SupportedPlatform') == 'ios' and x.get('SupportedPlatformVariant') == 'simulator' for x in libs), libs
assert any(x.get('SupportedPlatform') == 'ios' and x.get('SupportedPlatformVariant') is None for x in libs), libs
assert any(x.get('SupportedPlatform') == 'macos' for x in libs), libs
print(f'PASS: {version} combined XCFramework has iOS device + iOS simulator + macOS; upstream={sha}')
PY

rm -rf "$OFFICIAL_XCFRAMEWORK"
cp -R "$PATCHED_XCFRAMEWORK" "$OFFICIAL_XCFRAMEWORK"

# Xcode must see the simulator variant after replacement.
python3 - "$OFFICIAL_XCFRAMEWORK" <<'PY'
import plistlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
with (root / 'Info.plist').open('rb') as fh:
    libs = plistlib.load(fh).get('AvailableLibraries', [])
if not any(x.get('SupportedPlatform') == 'ios' and x.get('SupportedPlatformVariant') == 'simulator' for x in libs):
    raise SystemExit('combined artifact lost the iOS simulator slice')
print('PASS: DerivedData llama artifact is simulator-capable')
PY

cat > "$WORK_ROOT/receipt.txt" <<EOF
llama_version=$LLAMA_VERSION
upstream_sha=$UPSTREAM_SHA
official_artifact=$OFFICIAL_XCFRAMEWORK
simulator_source=exact upstream tag
shipping_binary=official SwiftPM XCFramework device slice
EOF
