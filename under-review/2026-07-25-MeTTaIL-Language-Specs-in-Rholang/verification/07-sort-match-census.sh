#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Produce-path sorting — nothing re-sorts a programmatic Par
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      §III.9's verified-negative leg
# FIPS CLAIM  6 ::sort_match( invocations, all inside source compilation or substitution;
#             none on the produce path
# RUN FROM    anywhere; pass the f1r3node root as $1 or set F1R3NODE_ROOT
# LAST RUN    2026-07-25 against f1r3node rust/dev @ 95be4feb
# EXPECTED    first command 6 lines; second command NO output
# TEETH TEST  ★ RECORDED FAILURE MODE 3 — a path that does not exist searches nothing.
#             rspace_plus_plus is the CRATE name; the DIRECTORY is rspace++. A command
#             spelled with the crate name matches no path, and grep reports that on
#             stderr while still exiting 0 — so the empty result reads exactly like a
#             verified negative when in fact a third of the stated search space was
#             never searched. Corrected, the claim does hold; uncorrected, it was
#             unsupported and looked identical.
#             
#             Also: match on '::sort_match(' and not on 'sort_match'. The bare form
#             returns 15, of which 9 are use lines, import continuations, and one
#             pub mod — the annotation '2 prod sites' on a 15-line output was itself a
#             defect.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FN=${1:-${F1R3NODE_ROOT:-$HERE/../../../../f1r3node}}
[ -d "$FN/.git" ] || { echo "no f1r3node at $FN — pass it as \$1 or set F1R3NODE_ROOT" >&2; exit 2; }
cd "$FN" || exit 2

echo "── the invocation sites (6; the two ParSortMatcher ones first) ──"
grep -rn '::sort_match(' rholang/src/rust/interpreter/

echo "── the three places a produced Par could be re-sorted before hashing (expect NOTHING) ──"
grep -rln 'sort_match\|ParSortMatcher\|Sortable' \
     rspace++/src/ \
     rholang/src/rust/interpreter/reduce.rs \
     rholang/src/rust/interpreter/rho_runtime.rs
