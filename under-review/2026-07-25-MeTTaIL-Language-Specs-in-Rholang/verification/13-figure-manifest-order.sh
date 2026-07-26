#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Figure manifest order matches embed order
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      that PALETTE's '# in document' column is the reading order
# FIPS CLAIM  figure 10 = 11-debugging-stations (§XII.2); figure 11 = 10-work-item-dag (§XIII.4)
# RUN FROM    anywhere (resolves the document relative to this script)
# LAST RUN    2026-07-25 against the working .md
# EXPECTED    22 lines — 11 figures, each an embed plus its PlantUML-source link
# TEETH TEST  swap two figure embeds in the .md and the printed order stops matching the
#             manifest table. The file-number suffix and the reading order genuinely
#             DISAGREE for the last two rows; that is recorded in PALETTE rather than
#             'fixed' by renaming files, because the numbers are stable identifiers.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIPS=$(dirname "$HERE")
cd "$FIPS" || exit 2
doc=2026-07-25-MeTTaIL-Language-Specs-in-Rholang.md

grep -n '](diagrams/[0-9]' "$doc"
