#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
EXPECTED_BUNDLE_ID=${EXPECTED_BUNDLE_ID:-com.joey.NovaForge}
EXPECTED_TEAM_ID=${EXPECTED_TEAM_ID:-93MYZUV85K}

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 /absolute/path/to/NovaForge.app" >&2
  exit 2
fi

APP_PATH=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
INFO_PLIST="$APP_PATH/Info.plist"
[ -f "$INFO_PLIST" ] || { echo "candidate has no Info.plist" >&2; exit 2; }

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)
EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)
PLATFORM=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$INFO_PLIST" 2>/dev/null || true)
EXECUTABLE_PATH="$APP_PATH/$EXECUTABLE_NAME"

[ "$BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || {
  echo "candidate bundle id is $BUNDLE_ID, expected $EXPECTED_BUNDLE_ID" >&2
  exit 1
}
[ "$PLATFORM" = "iPhoneOS" ] || {
  echo "candidate platform is $PLATFORM, expected iPhoneOS" >&2
  exit 1
}
[ -n "$EXECUTABLE_NAME" ] && [ -f "$EXECUTABLE_PATH" ] || {
  echo "candidate executable is missing" >&2
  exit 1
}

SIGNING_TEXT=$(codesign -d --verbose=4 "$APP_PATH" 2>&1 || true)
TEAM_ID=$(printf '%s\n' "$SIGNING_TEXT" | sed -n 's/^TeamIdentifier=//p' | head -1)
[ "$TEAM_ID" = "$EXPECTED_TEAM_ID" ] || {
  echo "candidate signing team is ${TEAM_ID:-missing}, expected $EXPECTED_TEAM_ID" >&2
  exit 1
}
codesign --verify --deep --strict "$APP_PATH"

/usr/bin/python3 - "$ROOT_DIR" "$APP_PATH" "$EXECUTABLE_PATH" "$BUNDLE_ID" "$TEAM_ID" "$PLATFORM" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
app = Path(sys.argv[2]).resolve()
executable = Path(sys.argv[3]).resolve()
bundle_id, team_id, platform = sys.argv[4:]

source_roots = [
    root / "AgentPad",
    root / "NovaForgeWidgets",
    root / "Packages" / "AgentHarnessKit" / "Sources",
    root / "Vendor" / "swift-llama-cpp" / "Sources",
]
source_files = [
    root / "AgentPad.xcodeproj" / "project.pbxproj",
    root / "AgentPad.xcodeproj" / "project.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved",
    root / "Packages" / "AgentHarnessKit" / "Package.swift",
    root / "Vendor" / "swift-llama-cpp" / "Package.swift",
]
compiled_suffixes = {
    ".swift", ".metal", ".h", ".m", ".mm", ".c", ".cc", ".cpp",
    ".plist", ".entitlements", ".xcconfig", ".json", ".strings",
    ".stringsdict", ".storyboard", ".xib", ".png", ".jpg", ".jpeg",
    ".heic", ".pdf", ".svg", ".ttf", ".otf",
}

for source_root in source_roots:
    if not source_root.exists():
        continue
    for path in source_root.rglob("*"):
        if not path.is_file() or ".build" in path.parts:
            continue
        if path.suffix.lower() in compiled_suffixes or ".xcassets" in path.parts:
            source_files.append(path)

source_files = sorted({path.resolve() for path in source_files if path.is_file()})
executable_mtime_ns = executable.stat().st_mtime_ns
stale = [
    str(path.relative_to(root))
    for path in source_files
    if path.stat().st_mtime_ns > executable_mtime_ns
]

manifest_hasher = hashlib.sha256()
file_count = 0
byte_count = 0
entries = (item for item in app.rglob("*") if item.is_file() or item.is_symlink())
for path in sorted(entries, key=lambda item: item.relative_to(app).as_posix()):
    relative = path.relative_to(app).as_posix().encode("utf-8")
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    content_hash = hashlib.sha256()
    if path.is_symlink():
        target = os.readlink(path).encode("utf-8")
        content_hash.update(b"symlink\0")
        content_hash.update(target)
        byte_count += len(target)
        entry_kind = b"symlink"
    else:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                content_hash.update(chunk)
                byte_count += len(chunk)
        entry_kind = b"file"
    manifest_hasher.update(len(relative).to_bytes(8, "big"))
    manifest_hasher.update(relative)
    manifest_hasher.update(entry_kind)
    manifest_hasher.update(mode.to_bytes(4, "big"))
    manifest_hasher.update(content_hash.digest())
    file_count += 1

report = {
    "schemaVersion": 1,
    "status": "pass" if not stale else "stale",
    "bundleID": bundle_id,
    "teamID": team_id,
    "platform": platform,
    "candidateManifestSHA256": "sha256:" + manifest_hasher.hexdigest(),
    "candidateFileCount": file_count,
    "candidateByteCount": byte_count,
    "compiledSourceCount": len(source_files),
    "newerSourceCount": len(stale),
    "newerSources": stale[:50],
}
print(json.dumps(report, indent=2, sort_keys=True))
raise SystemExit(0 if not stale else 1)
PY
