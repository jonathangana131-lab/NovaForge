#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 || ! -d "$1" ]]; then
  echo "usage: $0 /absolute/path/to/App.app" >&2
  exit 2
fi

APP_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

/usr/bin/python3 - "$APP_PATH" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

app = Path(sys.argv[1]).resolve()
if not app.is_dir():
    raise SystemExit(2)

manifest_hasher = hashlib.sha256()
file_count = 0
entries = (item for item in app.rglob("*") if item.is_file() or item.is_symlink())
for path in sorted(entries, key=lambda item: item.relative_to(app).as_posix()):
    relative = path.relative_to(app).as_posix().encode("utf-8")
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    content_hash = hashlib.sha256()
    if path.is_symlink():
        content_hash.update(b"symlink\0")
        content_hash.update(os.readlink(path).encode("utf-8"))
        entry_kind = b"symlink"
    else:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                content_hash.update(chunk)
        entry_kind = b"file"
    manifest_hasher.update(len(relative).to_bytes(8, "big"))
    manifest_hasher.update(relative)
    manifest_hasher.update(entry_kind)
    manifest_hasher.update(mode.to_bytes(4, "big"))
    manifest_hasher.update(content_hash.digest())
    file_count += 1

if file_count == 0:
    raise SystemExit("app bundle has no manifestable files")
print("sha256:" + manifest_hasher.hexdigest())
PY
