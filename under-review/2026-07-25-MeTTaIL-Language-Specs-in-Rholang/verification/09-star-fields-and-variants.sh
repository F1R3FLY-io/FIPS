#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# The five ★ fields, and the ValidationError variant count
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      §I.4's 'exactly five specification fields carry Rust' and W-2's '17 variants'
# FIPS CLAIM  ★₁…★₅ are the only Rust-bearing specification fields; ValidationError has 17
# RUN FROM    anywhere; pass the mettail-rust root as $1 or set METTAIL_ROOT
# LAST RUN    2026-07-25 against a72b57e0
# EXPECTED    ten field declarations (the five ★ plus five in the three non-spec groups); 17
# TEETH TEST  the variant count MUST use the variant-head pattern, not grep 'span: Span'
#             — the latter also matches Span::call_site() constructions inside impl
#             blocks and over-counts.
#             
#             The field predicate must allow for ALIASING: ast/src does `use super::*`
#             and spells the carrier field Option<Type>, so a literal search for
#             Option<syn::Type> silently misses it.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MR=${1:-${METTAIL_ROOT:-$HERE/../../../../mettail-rust}}
[ -d "$MR/.git" ] || { echo "no mettail-rust at $MR — pass it as \$1 or set METTAIL_ROOT" >&2; exit 2; }
cd "$MR" || exit 2

echo "── the Rust-bearing specification fields ──"
rg -n '^\s*pub [a-z_0-9]+\s*:\s*(Option<)?(Vec<)?(syn::)?(Type|Expr|TokenStream|RustCodeBlock)\b' \
   ast/src --glob '*.rs' | sort

echo "── ValidationError variants (expect 17) ──"
rg -n '^    [A-Z][A-Za-z0-9]* *[\{\(]' ast/src/validation/error.rs | wc -l
