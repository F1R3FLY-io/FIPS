# Verification apparatus

Instruments supporting the claims in
[`../2026-07-25-MeTTaIL-Language-Specs-in-Rholang.md`](../2026-07-25-MeTTaIL-Language-Specs-in-Rholang.md)
and [`../diagrams/PALETTE.md`](../diagrams/PALETTE.md).

**These live beside the document, not inside it.** A FIPS is read by reviewers and
implementers, and nobody implementing the specification needs a fence scanner. Embedding
the apparatus also created the hazard it was meant to close: an embedded `awk` extractor
went blind to a third of the document and, because it was *inside* the document, it
laundered the claim it was supposed to test. An external instrument a reader can go run
merely states a fact; an embedded broken one asserts a verified result. The document keeps
the **figures and the claims**; the **apparatus** is here.

## Assumed layout

Instruments resolve their targets relative to this directory, so they run from anywhere:

```
f1r3fly.io/
├── FIPS-mettail-in-rholang-specs/
│   └── under-review/2026-07-25-MeTTaIL-Language-Specs-in-Rholang/
│       ├── 2026-07-25-MeTTaIL-Language-Specs-in-Rholang.md
│       ├── diagrams/
│       └── verification/          ← you are here
├── mettail-rust/                  ← ../../../../mettail-rust
└── f1r3node/                      ← ../../../../f1r3node
```

If the sibling worktrees are elsewhere, override per run:

```sh
./04-ident-field-derivation.sh /path/to/mettail-rust
METTAIL_ROOT=/path/to/mettail-rust ./06-w12-channel-census.sh
F1R3NODE_ROOT=/path/to/f1r3node   ./07-sort-match-census.sh
```

An instrument that cannot find its target **exits 2 with a message** rather than
succeeding vacuously — see failure mode 3 below for why that matters.

## Revision pins

| Thing | Pin | Used by |
| --- | --- | --- |
| `mettail-rust` verification base | `a72b57e0` | every `[Implemented]` badge, line number and count |
| `mettail-rust` re-check revision | `39e523cb` | the `^Z`/`^S` rename landed here; `reserved_subst_trs_labels()` is still 19 |
| `f1r3node` | `rust/dev` @ `95be4feb` | 07 only |
| `mettail-rust` branch `modules` | `cc36a0d8` | the `[Branch]` citations (read by hand) |
| MeTTaIL prototype | `dev` @ `3343fbe` | `GSLT/src/test/module/` (read by hand) |

★ **Always `git show <rev>:<path>`, never a checkout `grep`.** The development tree is
worked on continuously and is routinely dirty. The `^Z`/`^S` rename was, for a period,
present *only* as uncommitted working-tree edits — and a checkout `grep` reported it as
landed, which is how it reached a draft of this FIPS marked `[Implemented]` before it was.
It has since genuinely landed, at `39e523cb`, and the difference between those two states
is visible only through `git show`. Instrument **08** exists to make the committed state
re-checkable, and its teeth test *is* that mistake.

## Instruments

| # | File | Checks | Expected |
| --- | --- | --- | --- |
| 01 | `01-corpus-census.py` | native-block census (§V.2) | 245 / 42 / 14 / 144-130 |
| 02 | `02-acronym-coverage.sh` | every acronym has a Terminology row | no output (42 detected) |
| 03 | `03-grammar-closure.sh` | §III.4.2 nonterminal closure | `NativeEval` only |
| 04 | `04-ident-field-derivation.sh` | the gate union's derivation rule | 64 rows incl. `JoinPatternDecl` |
| 05 | `05-auto-injection-labels.sh` | no auto-injected label starts with `^` | 13 sites |
| 06 | `06-w12-channel-census.sh` | W-12's site census | 25 + 27 |
| 07 | `07-sort-match-census.sh` | nothing re-sorts a produced `Par` | 6 lines; then nothing |
| 08 | `08-revision-matrix.sh` | the pin, and what has moved since | 8 lines |
| 09 | `09-star-fields-and-variants.sh` | the five ★ fields; 17 `ValidationError` variants | 10 fields; 17 |
| 10 | `10-palette-tiers.sh` | palette tiers 1 and 2 | no output |
| 11 | `11-palette-latex-quotes.sh` | no quote inside `<latex>` | `clean` |
| 12 | `12-diagram-reproducibility.sh` | SVGs reproducible **and** committed copies current | no output |
| 13 | `13-figure-manifest-order.sh` | manifest order = embed order | 22 lines |
| 14 | `14-markdown-structure.sh` | fences, math, tables, fragments, `§` refs | 302/0, 19, 0, 26/0, 0, 0 |
| 15 | `15-hashbag-order-probe/` | `HashBag` order is per-instance | orders differ |
| 16 | `16-corpus-counts.sh` | 31/35 languages, 18 options, 1 guards | 31 / 35 / 18 |

`run-all.sh` runs every instrument in order.

## ★ The teeth tests, and why they are the point

Every instrument's header carries a **teeth test**: a specific mutation that must make it
report. An instrument never observed to fail is not evidence — it is an untested assertion
wearing a shell prompt. Each of these was actually performed:

| Instrument | Mutation | Result |
| --- | --- | --- |
| 02 | delete the `AST` or `LHS` Terminology row | prints that acronym — **fires** |
| 03 | drop the `::=` continuation join | falsely reports 3 productions that DO exist |
| 10 tier 1 | re-key one figure's `#DCFCE7` to `P99` | `HEX->MANY KEYS` — **fires** |
| 10 tier 2 | delete a legend row whose fill is still used | `UNLEGENDED FILL` — **fires** |
| 12 | edit a `.puml` without re-rendering | `STALE COMMITTED` — **fired for real** |
| 14 | let an inline math span wrap a line break | reports it — **fired twice for real** |
| 16 | run against the checkout, not the pin | 30/34 instead of 31/35 — **fired for real** |

## ★★ Three recorded failure modes — how a *passing* check can be wrong

These are the hardest things in this set to rediscover, because in every case the
instrument reported success.

**1. A parity toggle is not a fence scanner.** `awk '/^```/{f=!f;next} !f'` inverts on the
bare three-backtick line that is *content* inside §VII.2's four-backtick block, then stays
inverted: 1,700+ lines of prose went unexamined — the whole References section among them
— while code was fed in as prose, and the sweep still printed nothing. It also never
matches the document's four *indented* fences. Instruments 02 and 14 use a scanner that
records the opening run length and tolerates ≤3 leading spaces, per CommonMark.

**2. Mention is not definition.** An oracle built from "every all-caps token in
§Terminology" passes a term that merely appears inside another term's gloss. `AST` passed
that way for several review rounds, appearing in the `rhoapi::Par` row while being
expanded nowhere. Instrument 02's oracle is the set of **row keys**, plus an allow-list
whose every entry carries its reason — so what is waived is visible rather than implicit.

**3. A path that does not exist searches nothing.** `rspace_plus_plus` is the *crate*
name; the *directory* is `rspace++`. A command spelled with the crate name matches no
path, and `grep` reports that on stderr while still exiting 0 — so the empty result reads
exactly like a verified negative when in fact a third of the stated search space was never
searched. Corrected, the claim does hold; uncorrected, it was unsupported and looked
identical. This is why the instruments here `exit 2` when a target is missing.

★ A fourth, in the *tooling* rather than the document: instrument 16 returned 30/34 when
run against the working checkout instead of the pin. That is the same checkout-versus-
revision error the revision matrix (08) exists to prevent, recurring one layer down in an
instrument that was supposed to be doing the checking. It now `git archive`s the base into
a temp directory and measures that.

## What is NOT mechanizable

PALETTE's **tier 3** — "is this figure's gloss a *specialization* of the palette concept,
or a *substitution* for it?" — is a reading. Tiers 1 and 2 are greps and are instrument 10.
The last defect to survive review was tier-3-only: figure 8's `backends` box was
internally consistent and legended, and still asserted "these four generators carry no
Rust", which the document elsewhere disproves for two of the four. No grep would have
caught it, and PALETTE says so rather than implying otherwise.
