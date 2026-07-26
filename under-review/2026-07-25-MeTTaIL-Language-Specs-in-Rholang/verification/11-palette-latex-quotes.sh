#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# No quote character inside a <latex> span
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      PALETTE's escaping rule
# FIPS CLAIM  '<latex> is reserved for genuine mathematical formulae, and must contain no quote'
# RUN FROM    anywhere (resolves diagrams/ relative to this script)
# LAST RUN    2026-07-25 against the working .puml set
# EXPECTED    the word 'clean'
# TEETH TEST  put \texttt{"lib"} inside a <latex> span. The sweep prints the line, and
#             the rendered SVG shows a PAIR OF APOSTROPHES rather than quotes —
#             JLaTeXMath substitutes silently, so without this sweep the defect is
#             visible only by rasterizing and looking.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$(dirname "$HERE")/diagrams" || exit 2
grep -n '<latex>[^<]*"' *.puml && echo "VIOLATION" || echo "clean"
