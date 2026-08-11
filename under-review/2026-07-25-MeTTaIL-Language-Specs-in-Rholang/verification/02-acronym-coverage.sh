#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Acronym coverage — every acronym has a Terminology row
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      that no all-caps prose token used as an acronym lacks a definition
# FIPS CLAIM  Terminology's scope statement: every acronym this document uses is defined there
# RUN FROM    anywhere (resolves the document relative to this script)
# LAST RUN    2026-07-25 against the working .md
# EXPECTED    no output; 42 acronyms detected over ~5250 lines of prose
# TEETH TEST  delete the AST or LHS row from Terminology — it prints that acronym.
#             VERIFIED FIRES.
#             
#             ★ RECORDED FAILURE MODE 1 — the parity toggle.
#             The obvious fence remover, awk '/^```/{f=!f;next} !f', is a PARITY
#             TOGGLE. The document contains a four-backtick block whose CONTENT
#             includes a bare three-backtick line (§VII.2's FLT fence example, which
#             must quote a fence to show one). A toggle flips on that content line,
#             inverts permanently, and from there drops every remaining line of prose
#             while feeding code in as prose — 1,700+ lines went unexamined, including
#             the whole References section, and the sweep still PASSED. It also never
#             matches the document's four INDENTED fences. The scanner below tracks
#             the opening run length and admits up to three leading spaces, per
#             CommonMark.
#             
#             ★ RECORDED FAILURE MODE 2 — mention is not definition.
#             An oracle built from 'every all-caps token in §Terminology' lets a term
#             pass by being MENTIONED inside another term's row. AST passed that way
#             for several rounds, appearing in the rhoapi::Par gloss while expanded
#             nowhere. The oracle below is the set of ROW KEYS plus one allow-list
#             whose every entry carries its reason, so what is waived is visible.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIPS=$(dirname "$HERE")
cd "$FIPS" || exit 2
doc=2026-07-25-MeTTaIL-Language-Specs-in-Rholang.md

# PROSE = the document minus fenced blocks, inline code spans, and link targets.
cat > /tmp/defence.awk <<'AWK'
{
  ind = match($0, /[^ ]/); ind = (ind ? ind - 1 : length($0))
  body = substr($0, ind + 1)
  n = 0; while (substr(body, n + 1, 1) == "`") n++
  if (!inblk) { if (n >= 3 && ind <= 3) { inblk = 1; open_n = n; next } }
  else {
    info = substr(body, n + 1); gsub(/[ \t]/, "", info)
    if (n >= open_n && info == "" && ind <= 3) inblk = 0
    next
  }
  print
}
AWK
sed 's/^> //' "$doc" | awk -f /tmp/defence.awk |
  sed 's/`[^`]*`//g; s/\[[^]]*\]([^)]*)//g' > /tmp/prose

# An ACRONYM is an all-caps prose token never occurring lower-cased in the prose,
# excluding this document's own structured identifiers (W-7, G1, RT4, numerals).
grep -oE '\b[A-Z][A-Z0-9]+(-[A-Z0-9]+)?\b' /tmp/prose | sort -u |
  grep -vE '^([A-Z]-?[0-9]+[a-z]?|RT[0-9]|I{1,3}|IV|VI{0,3}|IX|XI{0,3}V?|XIV|XV)$' |
  while read -r t; do
    grep -qE "\b$(printf '%s' "$t" | tr 'A-Z' 'a-z')\b" /tmp/prose || printf '%s\n' "$t"
  done | sort -u > /tmp/acronyms

# DEFINED = the Terminology tables' ROW KEYS — a term must have its own row.
sed -n '/^## Terminology/,/^## Part I /p' "$doc" |
  grep -oE '^\| \*\*[^*]+\*\*' | sed 's/^| \*\*//; s/\*\*$//' |
  tr '/' '\n' | tr -d ' `' | grep -E '^[A-Z][A-Z0-9-]+$' | sort -u > /tmp/defined

# ALLOWED = defined elsewhere, or out of scope. Every entry carries its reason.
cat > /tmp/allowed <<'EOF'
ACM        venue abbreviation inside a reference entry — out of scope
ASCII      assumed universal — out of scope
BLAKE3-256 width variant, defined in the BLAKE3 row
EPTCS      venue abbreviation inside a reference entry — out of scope
FNV        defined by the FNV-1a row
HOPL       venue abbreviation inside a reference entry — out of scope
LR         expanded inline in the GLR row
RFC        assumed universal; used only as a document number — out of scope
RISC-V     expanded at first use in the Abstract
UAX        expanded inline in the NFC / NFD / NFKC / NFKD row
UAX15      a citation key, not an acronym
EOF
cut -d' ' -f1 /tmp/allowed | sort -u > /tmp/allow

comm -23 /tmp/acronyms /tmp/defined | comm -23 - /tmp/allow
