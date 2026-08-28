#!/usr/bin/env bash
set -euo pipefail

# Write a per-run, content-addressed evidence inventory. This is deliberately
# a CI evidence helper: it records what a lane produced and never upgrades a
# simulator or generic build into a physical/Core AI claim.

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: $0 /absolute/output-dir lane pass|fail [derived-data-dir]" >&2
  exit 2
fi

OUTPUT_DIR=$(cd "$1" 2>/dev/null && pwd) || {
  echo "evidence output directory does not exist: $1" >&2
  exit 2
}
LANE=$2
STATUS=$3
DERIVED_DATA="${4:-}"
case "$STATUS" in
  pass|fail) ;;
  *) echo "evidence status must be pass or fail" >&2; exit 2 ;;
esac

MANIFEST_PATH="$OUTPUT_DIR/evidence-manifest.json"
HASH_PATH="$OUTPUT_DIR/evidence-manifest.sha256"
SOURCE_COMMIT=$(git -C "$OUTPUT_DIR" rev-parse HEAD 2>/dev/null || true)
SOURCE_ROOT=$(git -C "$OUTPUT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$SOURCE_ROOT" ]; then
  SOURCE_ROOT=$(cd "$(dirname "$OUTPUT_DIR")/.." 2>/dev/null && pwd || true)
fi
if [ -n "$SOURCE_ROOT" ]; then
  SOURCE_COMMIT=$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)
  SOURCE_TREE=$(git -C "$SOURCE_ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
else
  SOURCE_TREE=""
fi

/usr/bin/python3 - "$OUTPUT_DIR" "$MANIFEST_PATH" "$HASH_PATH" "$LANE" "$STATUS" "$SOURCE_COMMIT" "${SOURCE_TREE:-}" "$DERIVED_DATA" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

output, manifest_path, hash_path, lane, status, source_commit, source_tree, derived_data = sys.argv[1:]
output_path = Path(output).resolve()

def file_hash(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return "sha256:" + digest.hexdigest(), size

def tree_hash(path: Path) -> tuple[str, int, int]:
    digest = hashlib.sha256()
    file_count = 0
    byte_count = 0
    entries = (item for item in path.rglob("*") if item.is_file() or item.is_symlink())
    for item in sorted(entries, key=lambda candidate: candidate.relative_to(path).as_posix()):
        relative = item.relative_to(path).as_posix().encode("utf-8")
        metadata = item.lstat()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        if item.is_symlink():
            kind = b"symlink"
            content = os.readlink(item).encode("utf-8")
            content_hash = hashlib.sha256(b"symlink\0" + content).digest()
            byte_count += len(content)
        else:
            kind = b"file"
            content_hash_text, size = file_hash(item)
            content_hash = bytes.fromhex(content_hash_text.removeprefix("sha256:"))
            byte_count += size
        digest.update(kind)
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        digest.update(content_hash)
        file_count += 1
    return "sha256:" + digest.hexdigest(), file_count, byte_count

raw_files = []
for item in sorted(output_path.rglob("*"), key=lambda candidate: candidate.relative_to(output_path).as_posix()):
    if not item.is_file() or item.name in {Path(manifest_path).name, Path(hash_path).name}:
        continue
    digest, size = file_hash(item)
    raw_files.append({"path": item.relative_to(output_path).as_posix(), "bytes": size, "sha256": digest})

build = {"derivedDataPath": derived_data or None, "appManifestSHA256": None, "appFileCount": None, "appByteCount": None, "xctestrunSHA256": None}
if derived_data:
    derived_path = Path(derived_data).resolve()
    if derived_path.is_dir():
        apps = sorted(derived_path.rglob("NovaForge.app"), key=lambda candidate: candidate.as_posix())
        if apps:
            app_hash, app_count, app_bytes = tree_hash(apps[0])
            build.update({"appPath": str(apps[0]), "appManifestSHA256": app_hash, "appFileCount": app_count, "appByteCount": app_bytes})
        xctestruns = sorted(derived_path.rglob("*.xctestrun"), key=lambda candidate: candidate.as_posix())
        if xctestruns:
            build["xctestrunPath"] = str(xctestruns[0])
            build["xctestrunSHA256"], _ = file_hash(xctestruns[0])

manifest = {
    "schemaVersion": 1,
    "status": status,
    "claimsAllowed": False,
    "lane": lane,
    "source": {
        "commit": source_commit or None,
        "treeSHA256": ("sha256:" + source_tree) if source_tree else None,
    },
    "build": build,
    "rawEvidence": {"fileCount": len(raw_files), "files": raw_files},
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
manifest_digest, _ = file_hash(Path(manifest_path))
with open(hash_path, "w", encoding="utf-8") as handle:
    handle.write(manifest_digest + "  evidence-manifest.json\n")
PY

echo "Evidence manifest: $MANIFEST_PATH"
echo "Evidence manifest hash: $(awk '{print $1}' "$HASH_PATH")"
