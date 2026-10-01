#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Grammar closure — §III.4.2 has exactly one forward reference
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      that every nonterminal used on a right-hand side has a production
# FIPS CLAIM  'the grammar has no dangling symbol, and exactly one forward reference: NativeEval'
# RUN FROM    anywhere (resolves the document relative to this script)
# LAST RUN    2026-07-25 against the working .md
# EXPECTED    exactly one line: NativeEval
# TEETH TEST  drop the bare-identifier / ::= continuation join (the second awk) and it
#             also reports BehavioralPred, RefinementPred and TreeConstraint — all
#             three of which ARE produced in that section. Several productions are
#             written with the nonterminal on one line and ::= on the next; a sweep
#             that does not join them manufactures three false positives.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIPS=$(dirname "$HERE")
cd "$FIPS" || exit 2
doc=2026-07-25-MeTTaIL-Language-Specs-in-Rholang.md

sed -n '/^#### III.4.2/,/^### III.5 /p' "$doc" |
  awk '/^```text$/{f=1;next} /^```/{f=0} f'  |
  awk '{ if (p != "")            { print p " " $0; p=""; next }
         if ($0 ~ /^[A-Za-z][A-Za-z0-9_]*[ \t]*$/) { p=$0; next }
         print }'                            > /tmp/g
grep -oP '^\s*\K[A-Za-z][A-Za-z0-9_]*(?= *::=)' /tmp/g | sort -u > /tmp/def
sed -E 's/--.*//; s/\(\*.*\*\)//; s/^\s*[A-Za-z][A-Za-z0-9_]* *::=//; s/"[^"]*"//g' /tmp/g |
  grep -oE '\b[A-Z][A-Za-z0-9_]+\b' | sort -u > /tmp/use
comm -13 /tmp/def /tmp/use | grep -vE '^(Str|Int|Float|Bool|Nil|Map|List|Tuple|Set|Value)$'
