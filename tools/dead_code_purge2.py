#!/usr/bin/env python3
"""Dead member purge, take two. Paren-aware member ranges: a member's
signature may span lines (consume until parens balance), then the body is
brace-tracked. Every doomed block must independently balance braces AND
parens or it is skipped. Post-pass structural audit for orphaned tails."""
import re, pathlib

ROOT = pathlib.Path("/agent/workspace/novaforge/repo/AgentPad")
FAMILIES = {
 "PDV": ["Views/ProjectDashboardView.swift","Views/ProjectDashboard+CommandCenter.swift",
         "Views/ProjectDashboard+Overview.swift","Views/ProjectDashboard+Sections.swift",
         "Views/ProjectDashboard+Ledger.swift"],
 "Files": ["Views/FilesView.swift","Views/FilesView+Memory.swift","Views/FilesView+Browser.swift","Views/FilesView+Search.swift"],
 "Runs": ["Views/RunsView.swift","Views/RunCards.swift"],
 "Chat": ["Views/ChatView.swift","Views/ChatSupportViews.swift","Views/ChatComposer.swift",
          "Views/ChatHeaderStrip.swift","Views/ChatRunSnapshots.swift","Views/ChatProgressDrawer.swift",
          "Views/ChatMessages.swift","Views/ChatLiveAndToolViews.swift","Views/ChatOnboarding.swift","Views/ChatDrawerView.swift"],
}
SKIP = {"makeBody","body","description","id","reduce","defaultValue"}
member_re = re.compile(r'^    ((?:@\w+(?:\([^)]*\))?\s+)*)(?:private |fileprivate )?(?:static |lazy )*(?:var|func|let) ([A-Za-z_]\w*)')
attr_line = re.compile(r'^    @\w+(\([^)]*\))?\s*$')

def strip_strings_comments(ln):
    # crude but effective for balance counting: drop string literals + // comments
    ln = re.sub(r'"(?:[^"\\]|\\.)*"', '""', ln)
    ln = re.sub(r'//.*$', '', ln)
    return ln

def member_ranges(lines):
    out = []
    i = 0
    n = len(lines)
    while i < n:
        m = member_re.match(lines[i])
        if m and not lines[i].startswith("     "):
            name = m.group(2)
            start = i
            k = i - 1
            while k >= 0 and (attr_line.match(lines[k]) or lines[k].strip().startswith("//")):
                start = k
                k -= 1
            # consume signature until parens balance, then body until braces balance
            paren = 0
            brace = 0
            saw_brace = False
            j = i
            ok = False
            while j < n:
                s = strip_strings_comments(lines[j])
                paren += s.count("(") - s.count(")")
                brace += s.count("{") - s.count("}")
                if "{" in s:
                    saw_brace = True
                if saw_brace and brace <= 0 and paren <= 0:
                    ok = True
                    break
                if not saw_brace and paren <= 0 and j > i:
                    # signature closed with no body within this line -> stored/abstract
                    ok = True
                    break
                if not saw_brace and paren <= 0 and j == i and ("=" in s or "{" not in s):
                    # single-line stored property
                    ok = True
                    break
                j += 1
            if not ok:
                j = i  # give up on this member; move past decl line only
                out.append((name, start, i, False))
                i += 1
                continue
            out.append((name, start, j, True))
            i = j + 1
        else:
            i += 1
    return out

def universe():
    return "".join(f.read_text() for f in ROOT.rglob("*.swift"))

def block_balanced(lines, s, e):
    text = "\n".join(strip_strings_comments(l) for l in lines[s:e+1])
    return text.count("{") == text.count("}") and text.count("(") == text.count(")")

total_removed = 0
for round_no in range(1, 8):
    uni = universe()
    removed = 0
    for fam, files in FAMILIES.items():
        decl_counts = {}
        for f in files:
            for name, s, e, ok in member_ranges((ROOT/f).read_text().splitlines()):
                decl_counts[name] = decl_counts.get(name, 0) + 1
        for f in files:
            p = ROOT/f
            lines = p.read_text().splitlines()
            doomed_idx = set()
            for name, s, e, ok in member_ranges(lines):
                if name in SKIP or not ok: continue
                uses = len(re.findall(r'\b' + name + r'\b', uni))
                if uses <= decl_counts.get(name, 1):
                    if not block_balanced(lines, s, e):
                        print(f"SKIP unbalanced block {f}:{name}")
                        continue
                    print(f"round {round_no}: DELETE {f}: {name} ({e-s+1}L)")
                    doomed_idx.update(range(s, e+1))
                    removed += e - s + 1
            if doomed_idx:
                new_lines = [ln for idx, ln in enumerate(lines) if idx not in doomed_idx]
                p.write_text(re.sub(r'\n{4,}', '\n\n\n', "\n".join(new_lines)).rstrip() + "\n")
    total_removed += removed
    if removed == 0:
        break
print("total removed:", total_removed)

# structural audit: orphaned signature tails + per-file balance
orphan = re.compile(r'^\s*\) -> some View \{', re.M)
bad = False
for fam, files in FAMILIES.items():
    for f in files:
        t = (ROOT/f).read_text()
        for m in orphan.finditer(t):
            head = t[:m.start()].splitlines()[-14:]
            if not any(re.search(r'\bfunc \w+\($', ln.strip()) or "func " in ln for ln in head):
                print(f"ORPHAN TAIL in {f} near: {m.group(0)[:40]}")
                bad = True
        stripped = "\n".join(strip_strings_comments(l) for l in t.splitlines())
        if stripped.count("{") != stripped.count("}"):
            print(f"BRACE IMBALANCE {f}: {stripped.count('{')} vs {stripped.count('}')}")
            bad = True
        if stripped.count("(") != stripped.count(")"):
            print(f"PAREN IMBALANCE {f}: {stripped.count('(')} vs {stripped.count(')')}")
            bad = True
print("AUDIT", "FAILED" if bad else "CLEAN")
