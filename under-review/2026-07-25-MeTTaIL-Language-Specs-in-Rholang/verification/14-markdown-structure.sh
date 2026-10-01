#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Markdown structure — fences, math delimiters, tables, fragments, section refs
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      the five structural properties the documentation guidelines require
# FIPS CLAIM  0 math violations; fences balanced; 0 dangling section refs;
#             0 misaligned table rows; every literate fragment name bound
# RUN FROM    anywhere (resolves the document relative to this script)
# LAST RUN    2026-07-25 against the working .md
# EXPECTED    302 inline math spans / 0 violations; 19 display blocks;
#             fence balance 0; 26 fragments / 0 unbound; 0 dangling; 0 misaligned
# TEETH TEST  (a) let an inline math span wrap across a line break. CommonMark
#                 code spans cannot contain a newline, so the span is inert.
#                 FIRED TWICE FOR REAL during drafting.
#             (b) escaped pipes: the table check MUST strip backslash-pipe first,
#                 or it reports 20 false positives on rows that are correct.
#             (c) the fence scanner MUST track the opening run length. A parity
#                 toggle inverts on the bare fence INSIDE the four-backtick block
#                 in section VII.2 and goes blind to everything after it — see
#                 02-acronym-coverage.sh, where that defect actually happened.
# ═════════════════════════════════════════════════════════════════════════

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIPS=$(dirname "$HERE")
cd "$FIPS" || exit 2

python3 - "${1:-2026-07-25-MeTTaIL-Language-Specs-in-Rholang.md}" <<'PYINNER'
import re, sys
F = sys.argv[1]
raw = open(F).read().split("\n")
lines = [l.replace(r'\|', '') for l in raw]      # escaped pipes are not cell separators

def fences(seq):
    """CommonMark-correct: track the opening run length; ≤3 leading spaces."""
    d = ol = 0
    for l in seq:
        b = l.rstrip().lstrip("> ").rstrip()
        if b.startswith("```"):
            n = len(b) - len(b.lstrip("`")); info = b[n:].strip()
            if d == 0: d, ol = 1, n; yield ("open", l)
            elif n >= ol and info == "": d = 0; yield ("close", l)
            else: yield ("inner", l)
        else:
            yield ("code" if d else "prose", l)

prose = [l for k, l in fences(raw) if k == "prose"]
depth = sum(1 for k, _ in fences(raw) if k == "open") - sum(1 for k, _ in fences(raw) if k == "close")
spans = sum(len(re.findall(r'\$`[^`]*`\$', l)) for l in prose)
bad = [l for l in prose if "$" in re.sub(r'`[^`]*`', '', re.sub(r'\$`[^`]*`\$', '', l))]
txt = "\n".join(raw)
defined = set(re.findall(r'⟨([^⟩]+)⟩\s*≡', txt)); used = set(re.findall(r'⟨([^⟩]+)⟩', txt))
unbound = [u for u in used if u not in defined and u not in {"install", "G4", "G5a"}]
heads = set(re.findall(r'^#{2,5} (?:Part )?([IVX]+(?:\.\d+)*)', txt, re.M)) | \
        set(re.findall(r'^#{3,5} ([IVX]+\.\d+(?:\.\d+)?)', txt, re.M))
dangling = [r for r in set(re.findall(r'§([IVX]+(?:\.\d+)*)', txt))
            if r not in heads and r.split('.')[0] not in heads]
mis = 0; i = 0
kinds = [k for k, _ in fences(raw)]
while i < len(lines):
    if kinds[i] == "prose" and i + 1 < len(lines) and lines[i+1].lstrip("> ").startswith("| ---"):
        hdr = lines[i].count("|"); j = i + 2
        while j < len(lines) and lines[j].lstrip("> ").startswith("|"):
            if lines[j].count("|") != hdr: print(f"  MISALIGNED ROW {j+1}"); mis += 1
            j += 1
        i = j; continue
    i += 1
for l in bad: print("  MATH VIOLATION:", repr(l[:100]))
print(f"inline math {spans} / violations {len(bad)}")
print(f"display math {len(re.findall(chr(96)*3+'math', txt))}")
print(f"fence balance {depth} (0 = balanced)")
print(f"fragments {len(defined)} / unbound {len(unbound)} {unbound if unbound else ''}")
print(f"dangling section refs {len(dangling)} {dangling if dangling else ''}")
print(f"misaligned table rows {mis}")
PYINNER
