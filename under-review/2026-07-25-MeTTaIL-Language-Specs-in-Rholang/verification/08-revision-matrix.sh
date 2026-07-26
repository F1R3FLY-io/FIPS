#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Revision matrix — what the pin still describes, and what has moved
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      the three constants §IX.5 turns on, at the pin and at the revision where
#             the ^Z/^S rename landed
# FIPS CLAIM  a72b57e0: "Z"/"S", arity 2, arity 19
#             39e523cb: "^Z"/"^S", arity 0, arity 19   <- the rename LANDED here
#             ★ the C2 set stays 19 at BOTH; the Peano labels did not join it, and
#               §IX.5.1 gives the reason (it is a switch, not a census)
# RUN FROM    anywhere; pass the mettail-rust root as $1 or set METTAIL_ROOT
# LAST RUN    2026-07-25 against a72b57e0 and 39e523cb
# EXPECTED    8 lines; the first three differ between the revisions, the fourth does not
# TEETH TEST  run plain `grep` on the CHECKOUT instead of `git show` on a REVISION.
#             The rename existed for a period as uncommitted working-tree state, and a
#             checkout grep reported it as landed — which is exactly how it reached a
#             draft of this FIPS marked [Implemented] before it was. It has since
#             genuinely landed at 39e523cb, and the difference between those two states
#             is visible ONLY through git show. This instrument exists so that mistake
#             cannot be repeated by inspection.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MR=${1:-${METTAIL_ROOT:-$HERE/../../../../mettail-rust}}
[ -d "$MR/.git" ] || { echo "no mettail-rust at $MR — pass it as \$1 or set METTAIL_ROOT" >&2; exit 2; }
cd "$MR" || exit 2

for rev in a72b57e0 39e523cb; do
  echo "── $rev ──"
  git show "${rev}":rholang-codegen/src/rho_net_lower.rs |
    grep -nE 'PEANO_(ZERO|SUCC)_REFLECT_LABEL: &str|fn reserved_labels_outside'
  git show "${rev}":rholang-codegen/src/rho_net_subst_trs.rs |
    grep -n 'fn reserved_subst_trs_labels'
done
