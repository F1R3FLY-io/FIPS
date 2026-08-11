#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Run every instrument in order.
# ═══════════════════════════════════════════════════════════════════════════
# Instruments resolve their targets relative to this directory; see README.md
# for the assumed layout and the METTAIL_ROOT / F1R3NODE_ROOT overrides.
#
# Instruments 02, 03, 10, 11 and 12 are PASS/FAIL and should print nothing (11
# prints "clean"). The rest are CENSUSES and print their measurement, which is
# compared against the EXPECTED line in each header.
# ═══════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for f in "$HERE"/0*.sh "$HERE"/1*.sh; do
  case $(basename "$f") in run-all.sh) continue;; esac
  printf '\n════ %s ════\n' "$(basename "$f")"
  sh "$f" "$@"
done
printf '\n════ 01-corpus-census.py ════\n'; python3 "$HERE/01-corpus-census.py"
printf '\n(15-hashbag-order-probe is built and run by hand; see its README.)\n'
