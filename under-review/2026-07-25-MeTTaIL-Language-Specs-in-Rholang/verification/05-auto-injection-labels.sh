#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Auto-injection closure — no emitted label can begin with ^
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      the side condition §III.6 discharges for the gate/augmentation ordering
# FIPS CLAIM  13 format! sites partitioning into 6 new-label templates, 4 references to
#             labels the base already declares, and 3 diagnostic strings
# RUN FROM    anywhere; pass the mettail-rust root as $1 or set METTAIL_ROOT
# LAST RUN    2026-07-25 against a72b57e0
# EXPECTED    13 lines: 134 136 138 287 297 322 475 478 479 481 509 513 546
# TEETH TEST  add a 14th format! of a new shape and the three-group partition no longer
#             holds, so the closure argument must be re-discharged. The line bound
#             (NR<611) is the #[cfg(test)] boundary — if the test module moves, the
#             bound must move with it or test-only sites leak into the census.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MR=${1:-${METTAIL_ROOT:-$HERE/../../../../mettail-rust}}
[ -d "$MR/.git" ] || { echo "no mettail-rust at $MR — pass it as \$1 or set METTAIL_ROOT" >&2; exit 2; }
cd "$MR" || exit 2

git show a72b57e0:ast/src/auto_inject.rs |
  awk 'NR<611 && /format!\("/{print NR": "$0}'
