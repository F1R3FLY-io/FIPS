#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# SVG byte-reproducibility, and committed-vs-fresh
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      that rendering twice yields identical bytes — the property PlantUML is preferred FOR
#             AND that the committed SVG matches a fresh render
# FIPS CLAIM  'all 11 SVGs byte-reproducible'
# RUN FROM    anywhere (resolves diagrams/ relative to this script)
# LAST RUN    2026-07-25 against the working .puml set
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
for f in *.puml; do
  plantuml -tsvg -o "$A" "$f"; plantuml -tsvg -o "$B" "$f"
  cmp -s "$A/${f%.puml}.svg" "$B/${f%.puml}.svg" || echo "NON-REPRODUCIBLE: $f"
  cmp -s "${f%.puml}.svg"    "$A/${f%.puml}.svg" || echo "STALE COMMITTED: $f"
done
rm -rf "$A" "$B"
