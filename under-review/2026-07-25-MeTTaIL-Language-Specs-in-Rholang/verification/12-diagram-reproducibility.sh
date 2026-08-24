#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# SVG byte-reproducibility, and committed-vs-fresh
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      that rendering twice yields identical bytes — the property PlantUML is preferred FOR
#             AND that the committed SVG matches a fresh render
# FIPS CLAIM  'all 11 SVGs byte-reproducible'
# RUN FROM    anywhere (resolves diagrams/ relative to this script)
# LAST RUN    2026-08-02 against the working .puml set
# EXPECTED    no output
# TEETH TEST  edit a .puml without re-rendering -> 'STALE COMMITTED'. FIRED FOR REAL
#             during this document's revision, on 08-three-layers.puml.
#             
#             ★ Do NOT pass -nometadata. The twice-rendered comparison still passes,
#             but the committed SVGs then no longer match a default render, so the
#             reproducibility claim silently stops describing the committed artifact.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$(dirname "$HERE")/diagrams" || exit 2
A=$(mktemp -d); B=$(mktemp -d)
STATUS=0
JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Djava.awt.headless=true"
export JAVA_TOOL_OPTIONS
for f in *.puml; do
  if ! plantuml -tsvg -o "$A" "$f" 2>"$A/render.err"; then
    echo "RENDER FAILED: $f"
    cat "$A/render.err"
    STATUS=1
    continue
  fi
  if ! plantuml -tsvg -o "$B" "$f" 2>"$B/render.err"; then
    echo "SECOND RENDER FAILED: $f"
    cat "$B/render.err"
    STATUS=1
    continue
  fi
  if ! cmp -s "$A/${f%.puml}.svg" "$B/${f%.puml}.svg"; then
    echo "NON-REPRODUCIBLE: $f"
    STATUS=1
  fi
  if ! cmp -s "${f%.puml}.svg" "$A/${f%.puml}.svg"; then
    echo "STALE COMMITTED: $f"
    STATUS=1
  fi
done
rm -rf "$A" "$B"
exit "$STATUS"
