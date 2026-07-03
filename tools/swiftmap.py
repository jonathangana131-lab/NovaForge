#!/usr/bin/env python3
"""Map top-level Swift declarations with line ranges + in-file reference counts."""
import re, sys, pathlib, subprocess

def map_file(path):
    lines = pathlib.Path(path).read_text().splitlines()
    decl_re = re.compile(
        r'^((?:@\w+(?:\([^)]*\))?\s+)*)'          # attributes
        r'(private |fileprivate |internal |public )?'
        r'(final )?'
        r'(struct|class|enum|extension|protocol|typealias|actor)\s+([A-Za-z_][A-Za-z0-9_]*)'
    )
    decls = []
    for i, ln in enumerate(lines, 1):
        m = decl_re.match(ln)
        if m:
            decls.append({
                "line": i,
                "access": (m.group(2) or "internal").strip(),
                "kind": m.group(4),
                "name": m.group(5),
                "attrs": (m.group(1) or "").strip(),
            })
    # ranges: from decl start to next decl start - 1
    for j, d in enumerate(decls):
        d["end"] = (decls[j+1]["line"] - 1) if j+1 < len(decls) else len(lines)
        d["size"] = d["end"] - d["line"] + 1
    return decls, len(lines)

def refcount(name, root="AgentPad"):
    out = subprocess.run(["grep", "-rwo", name, root, "AgentPadTests", "AgentPadUITests", "--include=*.swift"],
                         capture_output=True, text=True).stdout
    return len(out.splitlines())

if __name__ == "__main__":
    path = sys.argv[1]
    decls, total = map_file(path)
    print(f"# {path} — {total} lines, {len(decls)} top-level decls")
    for d in decls:
        print(f'{d["line"]:>6}-{d["end"]:<6} {d["size"]:>5}L  {d["access"]:<12} {d["kind"]:<10} {d["name"]}  {d["attrs"]}')
