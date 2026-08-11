#!/bin/sh
# ═════════════════════════════════════════════════════════════════════════
# Gate-union derivation — every Ident-typed field of the model
# ═════════════════════════════════════════════════════════════════════════
# CHECKS      that §III.6's name-and-label gate covers every declared name
# FIPS CLAIM  the fourteen declaring families, incl. JoinPatternDecl.label reached two
#             optional levels down (guard_config? -> channels? -> join_patterns)
# RUN FROM    anywhere; pass the mettail-rust root as $1 or set METTAIL_ROOT
# LAST RUN    2026-07-25 against a72b57e0
# EXPECTED    64 rows, one per Ident-typed field, INCLUDING
#             'JoinPatternDecl  …  pub label: Ident,'
# TEETH TEST  remove JoinPatternDecl from the model and the row vanishes — which is
#             how that family was found in the first place: the sweep emitted the row
#             while the document's hand-written narration omitted it.
#             
#             ★ The awk resets its type scope on impl/fn/} lines. Without that reset a
#             stale scope attributes three `fn parse_*(label: Ident, …)` PARAMETERS to
#             the preceding type, and the output stops being 'one row per field'.
# ═════════════════════════════════════════════════════════════════════════
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MR=${1:-${METTAIL_ROOT:-$HERE/../../../../mettail-rust}}
[ -d "$MR/.git" ] || { echo "no mettail-rust at $MR — pass it as \$1 or set METTAIL_ROOT" >&2; exit 2; }
cd "$MR" || exit 2

for f in ast/src/language/model.rs ast/src/grammar.rs; do
  git show a72b57e0:$f | awk -v F="$f" '
    /^pub (struct|enum) /{s=$3; sub(/[<{].*/,"",s); inty=1; next}
    /^(impl|fn|pub fn|}) /{inty=0}
    /^}/{inty=0}
    inty && /: *Ident *,|: *Option<Ident> *,|: *Vec<Ident> *,/{printf "%-22s %s %s\n", s, F, $0}'
done
