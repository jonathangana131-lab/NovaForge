#!/usr/bin/env python3
"""Register new .swift files in project.pbxproj (classic format, objectVersion 60).
Usage: pbxproj_add.py <GroupDirName> <targets:app|app,tests> <File1.swift> [File2.swift ...]
IDs: AB-prefixed sequential, collision-checked."""
import sys, pathlib, re

if len(sys.argv) < 4:
    raise SystemExit("Usage: pbxproj_add.py <GroupDirName> <targets:app|tests|app,tests> <File1.swift> [File2.swift ...]")

ROOT = pathlib.Path(__file__).resolve().parents[1]
PBX = ROOT / "AgentPad.xcodeproj" / "project.pbxproj"
text = PBX.read_text()

group_dir = sys.argv[1]          # e.g. "Views"
targets = sys.argv[2].split(",") # app[,tests]
files = sys.argv[3:]
unknown_targets = set(targets) - {"app", "tests"}
assert not unknown_targets, f"unknown targets: {sorted(unknown_targets)}"

assert "AB00000000000000000" not in text or True
def next_ids(n, start_hint=1):
    ids = []
    i = start_hint
    while len(ids) < n:
        cand = f"AB{i:022d}"
        if cand not in text:
            ids.append(cand)
        i += 1
    return ids

n = len(files)
file_ids = next_ids(n)
build_ids = [f"AB1{fid[3:]}" for fid in file_ids] if "app" in targets else []
test_build_ids = [f"AB2{fid[3:]}" for fid in file_ids] if "tests" in targets else []
for bid in build_ids + test_build_ids:
    assert bid not in text, f"id collision {bid}"

# 1. PBXBuildFile section — insert after the ChatMessages build line (app target block)
bf_lines = []
if "app" in targets:
    for f, fid, bid in zip(files, file_ids, build_ids):
        bf_lines.append(f"\t\t{bid} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {f} */; }};")
if "tests" in targets:
    for f, fid, tbid in zip(files, file_ids, test_build_ids):
        bf_lines.append(f"\t\t{tbid} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {f} */; }};")
anchor = "/* End PBXBuildFile section */"
text = text.replace(anchor, "\n".join(bf_lines) + "\n" + anchor, 1)

# 2. PBXFileReference section
fr_lines = []
for f, fid in zip(files, file_ids):
    safe = f if f.replace(".","").replace("_","").isalnum() else f'"{f}"'
    fr_lines.append(f"\t\t{fid} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {safe}; sourceTree = \"<group>\"; }};")
anchor = "/* End PBXFileReference section */"
text = text.replace(anchor, "\n".join(fr_lines) + "\n" + anchor, 1)

# 3. Group children — find the PBXGroup with `path = <group_dir>;` and append children
grp_re = re.compile(r"(isa = PBXGroup;\s*children = \()([^)]*)(\);\s*path = " + re.escape(group_dir) + r";)", re.S)
m = grp_re.search(text)
assert m, f"group {group_dir} not found"
children_add = "".join(f"\t\t\t\t{fid} /* {f} */,\n" for f, fid in zip(files, file_ids))
text = text[:m.end(2)] + children_add.rstrip("\n") + "\n\t\t\t" + text[m.end(2):]

# 4. Sources phases. App phase contains "AppRootView.swift in Sources"; test phase contains "SandboxWorkspaceTests.swift in Sources".
def add_to_phase(marker, bids):
    global text
    idx = text.find(marker)
    assert idx >= 0, f"marker {marker} not found"
    # find the files = ( ... ); block that contains this marker
    open_idx = text.rfind("files = (", 0, idx)
    close_idx = text.find(");", idx)
    add = "".join(f"\t\t\t\t{bid} /* {f} in Sources */,\n" for f, bid in zip(files, bids))
    text = text[:close_idx] + add + "\t\t\t" + text[close_idx:]

if "app" in targets:
    add_to_phase("/* AppRootView.swift in Sources */,", build_ids)
if "tests" in targets:
    add_to_phase("/* SandboxWorkspaceTests.swift in Sources */,", test_build_ids)

PBX.write_text(text)
print(f"registered {n} files in {group_dir} for targets {targets}")
for index, (f, fid) in enumerate(zip(files, file_ids)):
    ids = []
    if "app" in targets:
        ids.append(build_ids[index])
    if "tests" in targets:
        ids.append(test_build_ids[index])
    print(" ", f, fid, *ids)
