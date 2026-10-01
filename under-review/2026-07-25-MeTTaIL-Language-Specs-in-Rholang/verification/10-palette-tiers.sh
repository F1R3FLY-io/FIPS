#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Palette tiers 1 and 2
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      hex<->key bijection, and that every semantic fill is legended in its own figure
# FIPS CLAIM  PALETTE's three-tier invariant; tier 3 is a reading, not a grep
# RUN FROM    anywhere (resolves diagrams/ relative to this script)
# LAST RUN    2026-07-25 against the working .puml set
# EXPECTED    no output from either tier
# TEETH TEST  TIER 1: re-key one figure's #DCFCE7 to P99 -> 'HEX->MANY KEYS'.
#             TIER 2: delete a legend row whose fill is still used -> 'UNLEGENDED FILL'.
#             BOTH VERIFIED FIRE.
#             
#             ★ Tier 2 exists because tier 1 CANNOT see an unlegended fill: a check
#             that reads only legend rows can confirm the legends agree with each other
#             and nothing more. Tier 2 catches the historical figure-3 nesting-shade
#             defect; tier 1 passes it.
#             
#             ★ Neither tier can see a tier-3 defect. Figure 8's backends box was
#             internally consistent AND legended and still asserted 'these four carry
#             no Rust', which the document elsewhere disproves for two of the four.
#             That one was found by reading.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$(dirname "$HERE")/diagrams" || exit 2

# TIER 1 — hex <-> key is a bijection across the whole set.
grep -hoE '\|<#[0-9A-F]{6}> *\| *\*\*P[0-9]+\*\*' *.puml |
  sed -E 's/\|<(#[0-9A-F]{6})> *\| *\*\*(P[0-9]+)\*\*/\1 \2/' | sort -u |
  awk '{h[$1]=h[$1]" "$2; k[$2]=k[$2]" "$1}
       END{for(x in h) if (split(h[x],a," ")>1) print "HEX->MANY KEYS: "x h[x];
           for(x in k) if (split(k[x],b," ")>1) print "KEY->MANY HEX:  "x k[x]}'

# TIER 2 — every semantic fill used in a figure has a legend row IN THAT FIGURE.
washes='#F8FAFC|#EEF2FF|#ECFDF5|#EFF6FF|#FEF2F2|#FFFBEB'
lines='#FFFFFF|#94A3B8|#64748B|#B45309|#B91C1C|#334155|#DC2626|#7C3AED|#BE185D'
for f in *.puml; do
  body=$(sed '/^legend/,$d' "$f"); leg=$(sed -n '/^legend/,$p' "$f")
  for h in $(printf '%s' "$body" | grep -oE '#[0-9A-F]{6}' | sort -u); do
    printf '%s' "$h" | grep -qE "^($washes|$lines)$" && continue
    printf '%s' "$leg" | grep -q "|<$h>" || echo "UNLEGENDED FILL: $f $h"
  done
done
