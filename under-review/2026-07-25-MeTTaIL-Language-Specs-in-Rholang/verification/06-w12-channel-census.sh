#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# W-12 channel census — firing-visible and carrier emitters
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      the site count §IX.6.1's invariant must cover
# FIPS CLAIM  25 direct + 27 constructor hits; 22 production; 20 in scope (5 sa: + 15 ac:)
# RUN FROM    anywhere; pass the mettail-rust root as $1 or set METTAIL_ROOT
# LAST RUN    2026-07-25 against a72b57e0
# EXPECTED    sweep 1 = 25 lines; sweep 2 = 27 lines, 5 of them past rho_net.rs:985
#             (the cfg(test) boundary), leaving 22 production call sites
# TEETH TEST  add a format!("ac:{op}") anywhere under */src/ and sweep 1 returns 26.
#             The point of stating W-12 as an INVARIANT over a swept census rather than
#             as an edit list is that an edit list reads as complete and goes stale in
#             silence — an earlier statement of it said 'two format-string changes'
#             and was short by eighteen.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MR=${1:-${METTAIL_ROOT:-$HERE/../../../../mettail-rust}}
[ -d "$MR/.git" ] || { echo "no mettail-rust at $MR — pass it as \$1 or set METTAIL_ROOT" >&2; exit 2; }
cd "$MR" || exit 2

echo "── (1) direct construction of a prefixed channel name ──"
git grep -nE 'format!\("(loc|col|cap|ac|ph|sa|e6a):' a72b57e0 -- '*/src/*.rs'
echo "── (2) construction through the two RhoNetChannel constructors ──"
git grep -nE 'RhoNetChannel::(location|set_automaton_trace)\(' a72b57e0 -- '*/src/*.rs'
