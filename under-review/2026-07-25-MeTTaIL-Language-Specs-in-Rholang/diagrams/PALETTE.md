# Diagram toolchain and pinned palette

All figures in this FIPS are **PlantUML** (`.puml`) rendered to committed SVGs with

```sh
cd diagrams && plantuml -tsvg *.puml
```

## Manifest

File numbers are stable identifiers, not a reading order; the FIPS introduces
them in the order below.

| # in document | File | Kind | Introduced in |
| --- | --- | --- | --- |
| 1 | `01-two-frontends.puml` | component / dataflow | §I |
| 2 | `02-langdef-anatomy.puml` | class | §I.4 |
| 3 | `03-tag-names-a-handler.puml` | component (two-level correspondence) | §II.1 |
| 4 | `08-three-layers.puml` | component (layered) | §III.2 |
| 5 | `09-value-form-schema.puml` | class (schema) | §III.4.2 |
| 6 | `05-native-block-tiers.puml` | **activity, with a decision node** | §V.1 |
| 7 | `04-spec-lifecycle.puml` | sequence | §VI |
| 8 | `06-backend-pipeline.puml` | **activity, swimlanes** | §VIII.1 |
| 9 | `07-security-boundary.puml` | component (trust boundary) | §IX |
| 10 | `11-debugging-stations.puml` | component (staged failure flow) | §XII.2 |
| 11 | `10-work-item-dag.puml` | component (dependency DAG) | §XIII.4 |

The file-number suffix and the "# in document" column **do not agree for the
last two rows**, and the table is ordered by the second: `11-debugging-stations`
is embedded in §XII.2 and `10-work-item-dag` in §XIII.4, so the debugging figure
is met first. The file names are stable identifiers assigned when each file was
created; the column is the reading order. [`../verification/13-figure-manifest-order.sh`](../verification/13-figure-manifest-order.sh)
prints the embeds in document order, which is how the
two columns are kept in agreement.

The diagram *kind* is chosen per figure rather than by habit. Figure 6 is an
activity diagram because its four `NativeEval` forms are **mutually exclusive**,
which a decision node states and parallel arrows do not. Figure 8 uses
**swimlanes** because its thesis is that the pipeline has two lanes with
different properties, so the lanes should be structural rather than tinted — and
for the same reason it must use `split` / `split again` / `end split` rather than
`detach`, so that both lanes visibly originate from the shared `LanguageDef`
node; a `detach` would leave the second lane a disconnected chain and destroy
the thesis. Figures 2 and 5 are class diagrams because they present record
structure. Figure 7 is a sequence diagram because its subject is an ordering of
steps over time. Figure 10 pairs an ordered chain of failure stations with a
fan-out of remedies, which no single ASCII box-drawing can align correctly.
Figure 11 is a DAG with fan-in and fan-out.

**No figure in this FIPS is ASCII art.** That is a rule, not a preference. Hand-drawn
box-drawing does not survive editing: interior separators drift out of alignment
with their own borders, intersections lose their `┬` / `┴` glyphs, and edges
between boxes are simply never drawn, so a reader is left inferring the flow from
adjacent arrowheads. Every figure is a `.puml` with a committed, byte-reproducible
SVG and palette colours from the table below.

PlantUML is preferred over Mermaid for every diagram type both support: PlantUML's
output is byte-reproducible (render twice, `cmp` — identical) and it typesets LaTeX
through the bundled JLaTeXMath into embedded vector SVG. Mermaid does neither. The
choice of diagram *kind* per figure follows the pgmcp diagramming catalog: PlantUML
covers component, class, sequence, activity, and swimlane figures, which is the whole
of what this FIPS needs; no figure here required Graphviz, D2, or TikZ.

[`../verification/12-diagram-reproducibility.sh`](../verification/12-diagram-reproducibility.sh)
renders each figure twice and compares, and also compares the committed SVG against a fresh render —
a figure edited without re-rendering is as much a defect as a non-reproducible
one, and that check has caught one.

## Pinned palette — one key, one concept, across the whole set

Every figure draws its **semantic** fills from this table and from nowhere else.
"Semantic" is the operative qualifier and is defined below the table.

### ★ What is pinned, stated exactly — because the obvious phrasing is false

The natural way to write this rule is *"a colour means the same thing in figure 5
that it means in figure 1."* That sentence is **not true of this set**, and it is
not true of any set of figures with per-figure legends, so it is not the rule.
Figure 1's `#DCFCE7` box is a backend generator; figure 5's is a grammar
production. Both are P5, and P5's concept covers both — but the two legends
gloss it differently, because a legend earns its place by saying what the colour
means *in the figure the reader is looking at*.

The invariant is therefore **three-tier**, and every tier is mechanically
checkable:

1. **Hex → key is global and injective.** Every occurrence of `#DCFCE7` in any
   figure is P5, and no other key uses `#DCFCE7`. This holds across all eleven
   figures with no exceptions.
2. **Every semantic FILL is legended in the figure that uses it.** This tier
   exists because tier 1 alone is unenforceable in practice: a check that reads
   only legend rows can only ever confirm that the legends agree with each
   other, and a fill with no legend row at all is invisible to it — which is
   exactly how a figure comes to shade its boxes by nesting depth rather than by
   meaning. Tier 3's "is it the right concept?" question can only be asked of a
   fill that some legend row actually claims.
3. **A key denotes one concept**, given below at the generality that covers
   every use. A figure's legend row states that concept **as instantiated in
   that figure** — a specialization, never a substitution. Figure 11's legend
   glossing P5 as "a delivered outcome" is admissible because a delivered
   outcome of the data lane *is* an instance of "fully declarative — no Rust";
   glossing it as "the adversary" would not be, and would be a defect.

**Tiers 1 and 2 are mechanical; tier 3 is a reading, not a grep.** The first two
are [`../verification/10-palette-tiers.sh`](../verification/10-palette-tiers.sh),
and both print nothing
on a clean set. Both have been teeth-tested: re-keying one figure's `#DCFCE7` to
a second key makes tier 1 report `HEX->MANY KEYS`, and deleting a legend row
whose fill is still used makes tier 2 report `UNLEGENDED FILL`.

| Key | Concept — stated to cover every use in the set | Hex | Tailwind name |
| --- | --- | --- | --- |
| **P1** | The **L0 layer** — Stay's extender authoring surface, its clauses, and work on it | `#FDE68A` | amber-300 |
| **P2** | The **existing Rust-embedded path** — the `language!` frontend, its DDL-text sugar, work on that lane, and (in an anatomy figure) a record that is declarative itself but composes a Rust-bearing member | `#FEF3C7` | amber-100 |
| **P3** | The **value layer** — specification values, the productions they are built from, the encoder/decoder pair over them, and a value under diagnosis | `#E0E7FF` | indigo-100 |
| **P4** | The **shared specification datatype** — `LanguageDef`, the L2 seam, and the layer a repair at that seam acts on | `#DBEAFE` | blue-100 |
| **P5** | **Fully declarative — carries no Rust**: a backend generator emitting installable DATA, a record or grammar production with no host code in it, and the outcome that lane delivers | `#DCFCE7` | green-100 |
| **P6** | **Rust-bearing** — a generator emitting Rust SOURCE, a record carrying a Rust type or Rust code, and work on that lane | `#FEE2E2` | red-100 |
| **P7** | Hard Rust-toolchain dependency | `#FCA5A5` | red-300 |
| **P8** | Runtime substrate — Rho machine, RSpace, FLT resolver, and an existing runtime implementation reached unchanged | `#BFDBFE` | blue-200 |
| **P9** | **Fail-closed gate**, and the fail-closed property it buys | `#A7F3D0` | emerald-200 |
| **P10** | **Unforgeable identity** — the fingerprint, the reflected tags derived from it, and the work and diagnoses that rest on it | `#FBCFE8` | pink-200 |
| **P11** | **Capability reference resolved against a registry** (handler / carrier / theory), the one production that may name one, and work on that registry | `#DDD6FE` | violet-200 |
| **P12** | **The adversarial dimension** — an adversary and the data it supplies, the silent hazard that creates, and the work that closes it | `#FDBA74` | orange-300 |
| **P13** | **The end asset** — what an attack would damage (a victim language's terms, host Rholang state) and what a compiler-free target must be able to run | `#C7D2FE` | indigo-200 |
| **P14** | An **out-of-band note** — verification, measurement, methodology, scoping, or design rationale | `#F1F5F9` | slate-100 |

### Container washes — the non-semantic fills, listed so the claim above is exact

A `package` background, a swimlane band, and a `rectangle` that exists only to
**enclose other rectangles** are containers, not concepts: they group figures rather
than denoting one, and giving them a P-key would make a colour mean two things. They are
therefore drawn from a separate, deliberately desaturated set —
every one a Tailwind `-50`, so no wash can be confused with a semantic fill from the
table above. This list is exhaustive.

> **★ The test is "groups rather than denotes", and enclosure is only its commonest
> form.** Figure 3's two *level* boxes are `rectangle`s rather than `package`s and enclose
> three children each; they take the neutral wash for that reason, and the levels are told
> apart by their titles. Tinting an enclosing box with a semantic key and its children with
> a lighter one produces shading by **nesting depth** — which reads as meaning, carries
> none, and is what tier 2 above exists to catch.
>
> A box may group without enclosing anything. Figure 8's `backends` box names four
> generators on one line as the terminus of the layer chain; it asserts nothing about them,
> and it must not, because **two of the four emit Rust source and two emit data** — a split
> figures 1 and 6 both draw, and which is their subject rather than figure 8's. Giving that
> box P5 would make it say *"these four carry no Rust"*, which is false of half of them.
> A collective noun takes the wash.
>
> ★ This case is **tier-3-only by construction**: hex→key stays consistent and the legend
> row is present, so tiers 1 and 2 both pass. A colour can be internally consistent,
> legended, and still assert something the document elsewhere disproves — which is the
> whole reason tier 3 is a reading and is stated as one.

| Wash | Hex | Tailwind | Used for |
| --- | --- | --- | --- |
| neutral container | `#F8FAFC` | slate-50 | `package` backgrounds in figures 1, 9, 10; figure 3's two enclosing *level* rectangles |
| authoring band | `#EEF2FF` | indigo-50 | figure 8's *Authoring* swimlane; figure 4's L1 package |
| data-lane band | `#ECFDF5` | emerald-50 | figure 8's *Semantics lane*; figure 4's one-decoder note |
| target band | `#EFF6FF` | blue-50 | figure 8's *Target* swimlane |
| source-lane band | `#FEF2F2` | red-50 | figure 8's *Syntax lane* |
| L0 band | `#FFFBEB` | amber-50 | figure 4's L0 package |

Four further colours are **line** colours, not fills, and are likewise outside the
table: `#FFFFFF` (`skinparam backgroundColor`), `#94A3B8` (note borders), `#64748B`
(sequence participant borders), and `#B45309` (activity diamond border).

One colour is a **text** colour: `#B91C1C` (red-700), used with `<b><color:…>` for the
single most easily-missed clause in a figure — figure 1's "a SECOND arrow into
`LanguageDef`" and figure 10's "NO ERROR ANYWHERE". It is red-700 rather than A2's
red-600 so that emphatic *text* is never mistaken for a *rejection arrow*, and it is
used at most once per figure; a second use would make it decoration.

## Pinned arrow semantics

| Key | Meaning | Colour | Style |
| --- | --- | --- | --- |
| **A1** | Ordinary dataflow, or an ordinary dependency | `#334155` slate-700 | solid |
| **A2** | Rejection — a gate refusing an input | `#DC2626` red-600 | solid |
| **A3** | An identity relation, or a protection or diagnosis derived from one | `#BE185D` pink-700 | solid |
| **A4** | An equality obligation (parity, round trip, fingerprint agreement) | `#7C3AED` violet-600 | **dashed** |
| **A5** | A path that does **not** exist | `#DC2626` red-600 | dashed, with a leading `✗` in the label |
| **A6** | A soft relation — a non-containment reference, or an ordering preference rather than a correctness constraint | `#334155` slate-700 | dotted |

Red is reserved for *rejection*; a **protection** — "cannot forge this identity" — is A3
pink, because it is a consequence of the identity relation and not a refusal.

**This table is enforced, not aspirational.** Two rules make it checkable, and both
were adopted because the alternative failed silently:

1. **A4 is dashed everywhere it appears.** A violet *solid* arrow would be an
   unpinned style that happens to share A4's colour, which is exactly how a reader
   comes to distrust the whole legend. Figure 4's `parse_ddl` arrow is dashed.
2. **A5's "crossed" is realized as a leading `✗` glyph in the label,** because
   PlantUML has no crossed-arrow style for component diagrams. A style the table
   names and no figure can draw is a table entry that will never be honoured; naming
   the realizable form is what makes the entry true.

Every arrow that carries meaning appears in the table, and every figure that uses a
non-A1 arrow repeats the relevant rows in its own legend, so a figure can be read
without this file open.

## Escaping rules for PlantUML labels

Three rendering hazards were verified empirically by rasterizing probe diagrams, and the
whole set now avoids all three.

1. **`\"` inside `<latex>…</latex>` typesets as an umlaut accent.** JLaTeXMath reads `\"`
   as the diaeresis command, so `\texttt{(\"op\", name)}` renders `(öp̈, name)`. Never put
   a double quote inside a LaTeX span.
2. **`\"` outside `<latex>` renders the backslash literally.** PlantUML does not unescape
   it; `**(\"op\", name)**` renders as `(\"op\", name)`.
3. **`*emphasis*` is not italics in PlantUML creole** — the asterisks are visible. Use
   `//…//` or `<i>…</i>`.

4. **`//emphasis//` must not span a line break inside a `note`.** PlantUML closes
   creole spans per line, so `//text` on one line and `text//` on the next renders
   both delimiters literally. Use `<i>…</i>` for any emphasis that might wrap.

The working idiom for a quoted tag literal is the HTML numeric entity inside a creole
monospace span: `""(&#34;op&#34;, name)""` renders `("op", name)` in a monospace face
with real ASCII quotes.

**`<latex>` is reserved for genuine mathematical formulae, and hazard 1 makes that a
rule rather than a convention.** A LaTeX span must contain **no quote character**,
which means a label that needs to show quoted source — `insertVersion(ret, "lib", …)`,
say — must use the `""…&#34;…&#34;…""` creole-monospace idiom instead, even where the
surrounding label is otherwise mathematical. Writing `\texttt{…"lib"…}` inside
`<latex>` does not produce quotes; JLaTeXMath renders each `"` as a pair of
apostrophes, silently. The rule is checkable with one sweep, and it must pass —

The rule is checkable in one sweep —
[`../verification/11-palette-latex-quotes.sh`](../verification/11-palette-latex-quotes.sh)
— and it must pass.
