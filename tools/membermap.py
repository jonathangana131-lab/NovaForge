#!/usr/bin/env python3
"""Map member-level declarations (4-space indent) of a Swift type body with sizes."""
import re, sys, pathlib

path = sys.argv[1]
start = int(sys.argv[2])   # struct body start line
end = int(sys.argv[3])     # struct body end line
lines = pathlib.Path(path).read_text().splitlines()

member_re = re.compile(
    r'^    ((?:@\w+(?:\([^)]*\))?\s+)*)'
    r'(private |fileprivate |internal |public )?'
    r'(static |lazy )*'
    r'(var|let|func|struct|enum|init)\s*([A-Za-z_][A-Za-z0-9_]*)?'
)
members = []
for i in range(start, min(end, len(lines))):
    ln = lines[i-1]
    if not ln.startswith("    ") or ln.startswith("     "):  # exactly 4-space indent
        continue
    m = member_re.match(ln)
    if m and (m.group(4) in ("func", "var", "struct", "enum") or (m.group(4) in ("let",) )):
        members.append({"line": i, "kind": m.group(4), "name": m.group(5) or "?", "attrs": (m.group(1) or "").strip(), "sig": ln.strip()[:110]})
for j, d in enumerate(members):
    d["end"] = (members[j+1]["line"] - 1) if j+1 < len(members) else end
    d["size"] = d["end"] - d["line"] + 1

# Only print sizable view builders / funcs (>= threshold), plus all stored props compactly
threshold = int(sys.argv[4]) if len(sys.argv) > 4 else 30
props = [d for d in members if d["kind"] in ("var", "let") and d["size"] < 5]
big = [d for d in members if d["size"] >= threshold]
print(f"# members: {len(members)}, stored/small props: {len(props)}, big(>= {threshold}L): {len(big)}")
print("\n== BIG MEMBERS ==")
for d in big:
    print(f'{d["line"]:>6}-{d["end"]:<6} {d["size"]:>5}L  {d["kind"]:<6} {d["name"]:<46} {d["attrs"][:40]}')
print("\n== PROPS (compact) ==")
for d in props:
    print(f'{d["line"]:>6} {d["sig"]}')
