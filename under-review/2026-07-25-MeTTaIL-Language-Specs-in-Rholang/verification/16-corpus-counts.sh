#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Corpus counts — shipped languages, fragments, composites, options, guards
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      §V.2's and §IV.2's language-level counts (01-corpus-census.py covers the
#             NATIVE-BLOCK counts instead)
# FIPS CLAIM  31 flat shipped languages, 35 recursively; 2 fragments + 1 composite;
#             options in 18 of 31; guards in exactly 1 (guarded_rho.rs)
# RUN FROM    anywhere; pass the mettail-rust root as $1 or set METTAIL_ROOT
# LAST RUN    2026-07-25 against a72b57e0
# EXPECTED    31 / 35 / four lines from the fragments+composites grep (three real
#             declarations plus one comment in composition/mod.rs) / 18 / guarded_rho.rs
# TEETH TEST  ★ THE CHECKOUT-VERSUS-REVISION TRAP, REAPPEARING IN THE TOOLING.
#             Run this against the working checkout instead of the pin and it returns
#             30 and 34 — the development tree is routinely dirty and gains languages,
#             so a checkout run silently contradicts the document while looking like a
#             reproduction of it. That is the SAME error the revision matrix (08) was
#             written to prevent, recurring one layer down in the instrument that was
#             supposed to be checking. The git-archive-into-a-temp-dir below is the
#             fix: it measures the REVISION, never the checkout.
#             
#             Secondary: guardoptsmoke.rs's `?g:Guard` is a terms{} PARAMETER SLOT, not
#             a guards{} block. A pattern loose enough to match it returns 2 and the
#             'guards by exactly one' claim silently becomes false.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MR=${1:-${METTAIL_ROOT:-$HERE/../../../../mettail-rust}}
[ -d "$MR/.git" ] || { echo "no mettail-rust at $MR — pass it as \$1 or set METTAIL_ROOT" >&2; exit 2; }
cd "$MR" || exit 2

BASE=a72b57e0
T=$(mktemp -d)
git archive $BASE languages/src | tar -x -C "$T"
cd "$T" || exit 2
rg -c --no-filename 'language!\s*\{' languages/src/*.rs | paste -sd+ | bc   # 31
rg -c --no-filename 'language!\s*\{' languages/src/    | paste -sd+ | bc   # 35
rg -n 'language_fragment!\s*\{|compose_languages!\s*\{' languages/src/     # 2 + 1
rg -l '^\s*options\s*\{' languages/src/*.rs | wc -l                        # 18
rg -l '^\s*guards\s*\{'  languages/src/*.rs                                # guarded_rho.rs
rm -rf "$T"
