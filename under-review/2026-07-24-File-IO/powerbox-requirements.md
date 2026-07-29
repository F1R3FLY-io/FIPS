# Powerbox — requirements & tracking

**Status:** design-in-progress; no code shipped. Consolidates all
powerbox-related requirements from the File I/O FIP spec and all
powerbox-related deferrals accumulated during Phase 6 slices 16-19.

Not itself a phase. When the powerbox slice lands, this document is
the acceptance-criteria checklist.

## 1. Purpose

The powerbox is the runtime component that hands each authenticated
principal (deployer) a **distinct, attenuated `Fs` capability** at
deploy time. Without it, the File I/O FIP's ocap discipline collapses
to a shared-Fs model where any deploy can affect any other.

Two things the powerbox is NOT:
- It is not a Rholang library (it lives in the Rust runtime, injecting
  per-deploy bindings before user code executes).
- It is not the static-provisioning config loader (Phase 7 produces
  the config; the powerbox consumes it).

## 2. Spec requirements

| # | Spec § | Requirement |
|---|--------|-------------|
| R-1 | §842-844 | `Fs.stdin()` / `stdout()` / `stderr()` return caps wrapping fds the powerbox supplies at Fs mint time. |
| R-2 | §865-867 | The Fs-cache does not cross Fs boundaries. Each principal receives its own Fs instance from the powerbox; those instances do not share state. |
| R-3 | §867 | The powerbox delivers the Fs cap via a `bundle+` on the powerbox's per-grantee `new` scope; caller code cannot fabricate another principal's Fs. |
| R-4 | §869 | Subordinates receive attenuated caps (File, Dir, membrane-wrapped), NOT `Fs`. Any subordinate who receives an `Fs` receives it directly from the powerbox with its own per-principal static bundle. |
| R-5 | §826, §874, §889 | Deploys obtain `Fs` via `getFS(`rho:io:fs:1.*`)` — a Versioned Registry lookup. The powerbox is the URN resolver for `rho:io:fs:1.*` and returns a per-principal cap. |
| R-6 | §Storage cases 4-6 | Powerbox default for stdio in non-oracle deploys is `/dev/null`-equivalent (empty stdin, discard stdout/stderr); powerbox may override per-principal per config. |
| R-7 | §425, §802 | The buffer allocator is published to the versioned registry at `rho:lang:buffer:1.0.0`. Per the implementation plan §37 and §494 the allocator is handed out per-principal by the powerbox — same treatment as `Fs`. |
| R-8 | §446, §674, §1321, §1362 | Allocation consults an external **quota agent** and returns `[false, "FSERR_QUOTA_EXCEEDED", msg]` on refusal. Quota policy is per-principal (§1321 wording: "the powerbox declined to grant the requested resource"); the quota agent is a powerbox-scoped resource. |
| R-9 | §1416 | On `"FSERR_REVOKED"` a subordinate re-requests a fresh capability from the powerbox. The powerbox's policy (deployerId match, time window, etc.) decides grant vs refuse. Requires a per-principal `getFs`-style re-request surface. NB: not to be confused with `"BUFERR_REVOKED"` (§402, §498), which is the Buffer agent's internal close-state tombstone — no powerbox interaction. |
| R-10 | §23 (Rationale §Ocap) | "Authority to touch the host filesystem comes only from statically-provisioned caps at genesis, delegated through the powerbox. There is no ambient 'just open any path.'" A user deploy binding raw `rho:io:fs:native:*` URNs violates this outright. |
| R-11 | Plan §37, §494, §532 | Interim stub Powerbox mints one `Fs` (and one allocator) per authenticated `deployerId` extracted from `NormalizerEnv`'s `rho:deploy:data` + `rho:system:deployerId:ops`. URN lookup shape stays stable across the eventual real-powerbox transition — only the delegation policy changes. |
| R-12 | Plan §115 | The static-provisioning bundle (Phase 7 output) is handed to the powerbox at genesis; the powerbox uses it to construct per-principal bundles. |
| R-13 | §1258, §1288, Plan §353-368 | Config schema distinguishes `oracle-static-*` from `consensus-static-*` buckets. Under Consensus mode `chown` is `FSERR_UNSUPPORTED` and `stat`/`entries` omit host-transient fields (mtime/ctime/atime/owner/group). The powerbox routes each principal to the right bucket based on the principal's mode; principals in Consensus mode receive Fs caps whose underlying handlers enforce field-omission and chown-refusal. |
| R-14 | §1424, §Interactive use cases | Optional `sys:ui` cap (`filePicker` / `dirPicker`) is available on interactive use cases (2, 3) only, gated by `--enable-ui-picker`. The powerbox decides whether to hand out `sys:ui` per principal; in non-interactive contexts or with the flag off, lookup returns `FSERR_UNSUPPORTED`. Not a File I/O FIP surface but the same powerbox handout model. |
| R-15 | §826, §874, §889 wildcard form | Deploys may use `` `rho:io:fs:1.*` `` (Versioned Registry wildcard) as well as `` `rho:io:fs:1.0.0` ``. The powerbox is the resolver for both forms — wildcard resolves to the highest compatible version installed at genesis, then produces a per-principal cap. |

## 3. Open issues

Issues surface as `PB-{severity}-N` (B blocker, M major, m minor).
Grouped by originating phase.

### Phase 1 — Native filesystem primitives

| ID | Severity | Description |
|----|----------|-------------|
| **PB-B-4** | Blocker | `handlers.rs::fs_open` (and every other native handler) trusts the caller-supplied `root` path unconditionally.  `safe_descend` guards only the `rel` portion against escape from the supplied root — the root itself is assumed already-canonicalized and symlink-checked.  Under the R-3 model this trust is safe: only the (blessed, per-principal) `Fs` agent constructs `root` from a powerbox-provisioned bundle.  Post-slice-19 with the URN filter removed (PB-B-1), user code supplies its own root and the whole sandbox collapses.  Same fix as PB-B-1 subsumes this. |
| **PB-B-2** | Blocker (was Slice 19 Security B-19-2) | `handle_table.rs` uses a per-runtime `HashMap<u64, FileHandle>` shared across all tenants with monotonic fd allocation.  `fs_close` / `fs_read` / `fs_write` / `fs_truncate` accept any fd with no ownership check.  Any deploy with fs-native URN access can iterate small fds and close/read/write files opened by any other tenant.  Predates Phase 6 — the ownership check was always missing; PB-B-1's filter had been keeping user code from exercising it. |

### Phase 2 — UTF-8 helpers and `concatBytes`

No powerbox surface — three stateless native helpers (`validUtf8PrefixLen`, `decodeUtf8`, `concatBytes`) with no capability content.

### Phase 3 — Buffer library + allocator

| ID | Severity | Description |
|----|----------|-------------|
| **PB-B-5** | Blocker | The allocator (`Allocator` agent in `Buffer.rho`) is not yet wired to a registry URN and has no per-principal delegation.  Per R-7 / R-11, when it ships the powerbox must hand out a distinct allocator per authenticated `deployerId` at `rho:lang:buffer:1.0.0`.  Same shape as Fs.  Not yet a runtime hole because the allocator is unpublished; becomes a blocker as soon as it lands. |
| **PB-M-6** | Major | `FSERR_QUOTA_EXCEEDED` quota-agent hook is deferred in Buffer.rho:641-651 with a TODO.  Per R-8 and spec §1362 the quota agent is a powerbox-scoped resource and is consulted by BOTH the allocator and the File I/O layer (`Fs.openFile`, `File.readInto`, stream materialization caps).  Powerbox slice must land the quota-agent surface and thread it through both call sites. |
| **PB-M-7** | Major | Allocator handout inside the Rholang genesis composition — like `Fs`, the `Allocator` agent is currently a module-level name in the FsGenesis new-scope (slice 19 `compose_fs_genesis_source`).  If exported to deploy scope directly it becomes a shared allocator (violates R-7).  Powerbox slice must gate `Allocator` export the same way as `Fs`. |

### Phase 4 — Stream library

| ID | Severity | Description |
|----|----------|-------------|
| **PB-m-4** | Minor | `Stream.rho` itself has no capability content — it's a pure composition primitive.  But its consumers (`File.chars`, `Dir.entries`, `Stdin.lines`, `Stdout.writeLines`) inherit whatever powerbox scoping their creating cap has.  When per-principal Fs lands, verify no Stream can be constructed by one principal and consumed by another via a shared side channel; document the invariant. |

### Phase 5 — File / Dir library

| ID | Severity | Description |
|----|----------|-------------|
| **PB-M-8** | Major | `File.rho` and `Dir.rho` store `canonRoot` in per-agent state as a trusted invariant (spec §Dir "canonRoot is IMMUTABLE from the initial ctor call: it is the boot-canonicalized sandbox root").  Under R-3, only the powerbox-provisioned Fs mints these agents with a canonicalized root.  Under slice-19's shared-Fs + no-URN-filter, user code can construct a File / Dir with any `canonRoot` by binding `rho:io:fs:native:*` directly and skipping the Fs.rho layer, or by exploiting PB-B-1 to reach the natives.  Same fix as PB-B-1. |
| **PB-M-9** | Major | `File.readInto` / `File.writeFrom` / `File.readLineInto` etc. accept a `Buffer` cap as an argument.  Under the eventual per-principal model, a caller's Buffer and their File must be co-tenant (both minted by the same principal's allocator + Fs).  Cross-tenant buffer-to-file writes are currently possible (both are shared), and after per-principal delegation there is no runtime check preventing Alice from passing her Buffer to Bob's File.write.  Powerbox slice or Phase 8 must decide: (a) allow (buffers are transferable caps), (b) refuse cross-tenant with FSERR_UNSUPPORTED, or (c) tag caps with principal at mint time and check at every method call. |

### Phase 6 — Fs agent + stdio + genesis

#### Blockers — must be closed before production

| ID | Source | Description | Fix option |
|----|--------|-------------|------------|
| **PB-B-1** | Slice 19 Security B-19-1 | The `is_internal_fs_native_urn` filter in `rho_runtime.rs` was removed so `fs_generator` could bind `rho:io:fs:native:1.0.0/*` URNs. Any user deploy can now `new fsOpen(`rho:io:fs:native:1.0.0/open`) in { fsOpen!("/", "etc/passwd", "r", *ack) }` and hit raw syscalls — remote root FS access on every validator. Violates R-10 outright. | See §5 fix options A, B, C. |
| **PB-B-3** | Slice 19 FIP B-19-1 | FsGenesis publishes at `rho:id:<hash>` (legacy `insertSigned`). Spec §826, §874, §889 all reference `getFS(`rho:io:fs:1.*`)` — a Versioned Registry URI that is NEVER wired. The canonical spec examples cannot resolve. | Powerbox resolves `rho:io:fs:1.*` directly (per R-5) — no versioned-registry mapping needed. Alternative: add `insertVersion` call to fs_generator so the versioned URI is a legacy Alias. |

#### Majors

| ID | Source | Description |
|----|--------|-------------|
| **PB-M-1** | Slice 19 shared-Fs simplification | fs_generator publishes ONE Fs instance. Two principals looking up `rho:id:...` share cache AND file handles. Alice's `openFile("logs")` returns a cap Bob can also see if he opens the same name. Violates R-2, R-3. |
| **PB-M-2** | Slice 18 stdio hardwired | Fs is minted with fds (0, 1, 2) at genesis. R-6 requires per-principal overrides (`/dev/null`-equivalent for non-oracle cases 4-6). |
| **PB-M-3** | Slice 18 Stdin/Stdout module scope | Stdin and Stdout are module-level agents in the FsGenesis new-scope. If any user code gains lexical access to those bundles (e.g., via a future test-harness leak), they can `Stdin!?(0)` directly and bypass Fs.stdin's future per-principal cap. Powerbox must ensure only `Fs` — never `Stdin`/`Stdout` — is exported to deploy scope. |
| **PB-M-4** | Slice 17 cache scoping | Per-Fs cache (implemented) is only useful if principals actually get distinct Fs instances (spec §867). Under the current shared-Fs MVP, the "cache does not cross Fs boundaries" property is vacuously satisfied because there is one Fs. |
| **PB-M-5** | Slice 16 empty bundle | Every openFile/openDir returns FSERR_UNSUPPORTED. Powerbox needs to pass the per-principal bundle produced by Phase 7's config loader into the Fs constructor. |
| **PB-M-10** | Spec §1416 revocation flow | No code path yet supports `FSERR_REVOKED` recovery.  Per R-9, when a cap is revoked the subordinate re-requests via the powerbox.  The re-request surface is currently just "look up `rho:io:fs:1.*` again"; powerbox slice must define whether that returns the SAME cap (already-revoked) or triggers a policy re-evaluation. |
| **PB-M-11** | Spec §867 membrane-isolation claim | Spec §867 explicitly asserts "Alice's membrane around her File cannot be bypassed by Bob because Bob never sees Alice's File."  Under the current shared-Fs MVP this claim is FALSE: Alice and Bob look up the same Fs, both call `openFile("shared/file.txt")`, and both receive the SAME File cap from the shared cache — Bob's copy is trivially unwrapped, bypassing Alice's membrane.  Distinct from PB-M-1 (cache-sharing) — this is the ocap-isolation claim explicitly failing.  Fixed by per-principal Fs (PB-M-1's fix subsumes this) but worth calling out as a load-bearing spec claim currently unmet. |
| **PB-M-12** | Spec §1258, §1418 + Plan §346 mode routing | Consensus vs Oracular mode is a per-principal (or per-node?) property.  The powerbox needs to know which mode applies for each `getFS` lookup and route to the corresponding config bucket (`consensus-static-*` vs `oracle-static-*`).  Related handler behavior (`chown` → FSERR_UNSUPPORTED in Consensus; `stat`/`entries` field omission) is driven by `ConsensusMode` enum threading (Plan §146) that must reach the per-principal handler dispatch. |

#### Minors

| ID | Source | Description |
|----|--------|-------------|
| **PB-m-1** | Slice 19 URN scheme | `rho:io:fs:native:1.0.0/*` URN names are private implementation detail. Powerbox slice should either (a) formalize in a spec §Native URNs section, or (b) rename to a scheme that makes their internal-only status obvious. |
| **PB-m-2** | Slice 18 fd type-guard | Fs constructor accepts fd args as unchecked Pars. Powerbox is the trust boundary — it should validate fds are `Int` before calling `Fs!?(...)`. |
| **PB-m-3** | Slice 19 stale runtime docstring | `rho_runtime.rs:783-786` block comment references the removed URN filter and cites Phase 6 as the legitimate holder. Update when powerbox lands to describe the actual mechanism. |
| **PB-m-5** | Plan §532 stub-vs-real transition | The plan explicitly calls out a two-step powerbox transition: interim stub (per-`deployerId` from `NormalizerEnv`) → real Powerbox FIP.  Slice must document the boundary so URN semantics (`getFs` shape) stay stable across the transition. |
| **PB-m-6** | Slice 20 FIP review Mi-20-2 | Blessed contracts still bind the legacy stdio URNs: `ListOps.rho:16` (`stdout(`rho:io:stdout`)`), `AuthKey.rho:21`, `PoS.rhox:123`, `match_example.rho:1`, `RegistryRealLifeTest.rho:1`.  Slice 20 emits no runtime warning (deprecation is documented in the FIP only), so these are cosmetic hygiene — the platform bundles legacy-API calls in its own code.  Migrate when convenient, not urgent.  Fix: switch each to `Fs.stdout()` via `getFS(`rho:io:fs:1.*`)`; depends on PB-M-1 (per-principal Fs delegation) so blessed contracts have a stable per-deploy Fs cap. |

## 4. Design questions

The powerbox slice must answer:

- **Q-1 — Blessed-deploy discrimination.** How does the URN resolver distinguish genesis-blessed deploys (allowed to bind fs-native URNs) from user deploys (blocked)?
  - Signer identity? (Deploy signed by `FS_GENERATOR_PK` bypasses filter.)
  - Deploy-context tag set by genesis pipeline?
  - Two separate `urn_map`s selected per deploy?
- **Q-2 — Per-principal Fs delegation mechanism.** How does the URN resolver produce a DIFFERENT Fs cap per lookup?
  - Mint a new Fs instance per `getFS(`rho:io:fs:1.*`)` lookup, keyed by the resolving deploy's `deployerId`?
  - Cache the per-deployer Fs across lookups within a single deploy? Across deploys?
- **Q-3 — Config wiring.** Where does the per-principal bundle come from?
  - Phase 7 produces `Vec<(logicalName, canonPath, kind, mode)>`. Powerbox reads this at boot, maps per-principal.
  - How does the powerbox know WHICH principal each `getFS` lookup is for? Presumably via `rho:deploy:data:deployerId`.
- **Q-4 — Stdio fd resolution.** For each principal, powerbox needs three fds. Options:
  - Boot config: `--oracle-stdin <path> --oracle-stdout <path> --oracle-stderr <path>`.
  - Default: (0, 1, 2) for oracle validators, /dev/null-equivalent for others.
- **Q-5 — Anonymous deploys.** What Fs does a deploy without a valid deployerId get?
  - Empty bundle + /dev/null stdio.
- **Q-6 — Fs lifetime.** Is a principal's Fs instance minted once per deploy? Once per validator run? Persisted across deploys within a shard-round?
  - Impacts R-2 cache semantics (whether cache spans deploys or is fresh per deploy).
  - Directly interacts with spec §Deferred "Cross-deployment agent lifetime" (FIP §Use case 4) — that item says "current design keeps agent state per-`RhoRuntimeImpl`; long-lived caps across deploy boundaries need a per-node table with its own eviction policy." Powerbox slice decides whether to ship the per-node table or defer with §Deferred.
- **Q-7 — Mode assignment.** How does the powerbox decide whether a principal is Consensus or Oracular?
  - Boot-time config listing which deployerIds are consensus vs oracular?
  - All principals identical mode based on node role?
  - Both — mixed shards with per-principal mode?
- **Q-8 — Config-schema evolution.** Phase 7's config layout (spec §1258-1288) uses static `{path, mode}` maps. If powerbox supports policies richer than "static-per-principal" (time windows, capability revocation lists, quota overrides), does the config schema grow? Or stay minimal and let the powerbox source policy separately?

## 5. Fix option catalog for PB-B-1 (URN filter)

Three implementable paths for restoring sandbox:

**Option A — Two URN maps.**
Build `urn_map` twice: `blessed_urn_map` includes all URNs (including `rho:io:fs:native:*`); `user_urn_map` filters them out. Select based on deploy signer at execution time.
- Pro: minimal code churn.
- Con: requires plumbing signer identity to the URN resolver.

**Option B — Env pre-population.**
Keep the filter enabled always. Pre-populate the genesis pipeline's `Env` with the fs-native URNs bound to their `Par` values BEFORE executing the fs_generator deploy. User deploys never see these bindings; the composed source works because its `new` clause finds the bindings in Env at normalization.
- Pro: no runtime signer check needed.
- Con: requires distinguishing genesis-Env construction from user-Env construction; may need normalizer changes.

**Option C — Signer whitelist at URN lookup time.**
Filter is unconditional in the urn_map, but the URN resolver consults a signer whitelist for fs-native URNs. Deploys signed by `FS_GENERATOR_PK` (or a broader "system-signer" set) bypass the filter.
- Pro: fine-grained; extensible to other blessed-only URNs.
- Con: URN resolution is currently a pure `HashMap::get`; adding conditional logic per URN requires refactor.

**Recommended:** Option A or B. Option A is simpler; Option B has cleaner ocap discipline (no runtime signer check needed once the Env is built).

## 6. Related code

**Runtime:**
- `rholang/src/rust/interpreter/rho_runtime.rs:783-798` — fs-native URN registration; docstring needs update.
- `rholang/src/rust/interpreter/rho_runtime.rs:1436-1452` — where the removed filter used to live.
- `rholang/src/rust/interpreter/system_processes.rs:279-291` — fs-native fixed-channel byte names.
- `rholang/src/rust/interpreter/handlers.rs` — the native syscall handlers (fs_open, fs_read, fs_close, ...) that would need owner-tag enforcement per PB-B-2.
- `rholang/src/rust/interpreter/handle_table.rs` — per-runtime `HashMap<u64, FileHandle>`; needs ownership tag if PB-B-1 isn't fixed by filter reinstatement.

**Genesis:**
- `casper/src/rust/genesis/contracts/fs_genesis.rs` — composed FsGenesis source; §MVP simplifications #1-#5 document the deferrals this doc consolidates.
- `casper/src/rust/genesis/contracts/standard_deploys.rs::fs_generator` — the deploy that publishes the shared Fs cap.
- `casper/src/rust/genesis/genesis.rs` — deploy sequence includes `fs_generator` after Registry, before PoS.

**Config (Phase 7):**
- Not yet implemented. Will produce `Vec<(logicalName, canonPath, kind, mode)>` — the input the powerbox consumes to construct per-principal bundles.

**Fs agent:**
- `casper/src/main/resources/Fs.rho` — constructor signature `(stdinFd, stdoutFd, stderrFd, bMap)`. Powerbox calls this with per-principal values.

## 7. Acceptance criteria (definition of done)

When the powerbox slice lands, all of the following must hold:

**Sandbox / ambient authority:**
- [ ] PB-B-1: user deploys binding `rho:io:fs:native:*` URNs are rejected at normalization; the fs_generator (or its powerbox-slice equivalent) still succeeds. Test: user-scope `new fsOpen(`rho:io:fs:native:1.0.0/open`) in { ... }` returns a normalization error.
- [ ] PB-B-2: either (a) the URN filter is back in place (subsumes this), or (b) `FileHandle` carries an owner tag and every native handler checks it.
- [ ] PB-B-4: `handlers.rs`'s trust in `root` is justified by the fact that only the powerbox-provisioned Fs supplies `root`. Test: verify no code path outside the Fs constructor reaches `fs_open` with a non-canonical root.
- [ ] PB-M-3: Stdin/Stdout module-level agents are NOT exported to user deploy scope. Test: user `new sin(<some-URN-for-Stdin>) in { sin!?(0) }` fails.
- [ ] PB-M-7: `Allocator` module-level agent is NOT exported to user deploy scope; only per-principal allocator caps from `rho:lang:buffer:1.0.0` are reachable.
- [ ] PB-M-8: user code cannot construct a File/Dir with arbitrary `canonRoot` — the only mint path is through a powerbox-provisioned Fs.

**Per-principal delegation:**
- [ ] PB-B-3: `getFS(`rho:io:fs:1.*`)` in a user deploy resolves to a working Fs cap.
- [ ] PB-B-5: `rho:lang:buffer:1.*` resolves to a per-principal Allocator cap.
- [ ] PB-M-1: two distinct deployers looking up `rho:io:fs:1.*` receive DIFFERENT Fs caps (structural inequality); Alice's `openFile("shared")` does not affect Bob's cache. Test parallels `fs_open_file_cache_does_not_cross_fs_boundaries`.
- [ ] PB-M-4: with per-principal Fs, the existing slice-17 cross-Fs cache tests (currently synthetic) are exercised on the actual production wiring.
- [ ] R-11 interim-stub semantics: `NormalizerEnv`'s `rho:deploy:data` + `rho:system:deployerId:ops` extraction produces the identity key for per-principal caching.

**Config / policy:**
- [ ] PB-M-2: config flags for per-principal stdio fds land; default policy for non-oracle deploys is /dev/null-equivalent.
- [ ] PB-M-5: Phase 7 bundle-config is consumed by the powerbox; a config that provisions `"config/theme.json"` for deployer X and NOT for deployer Y is reflected in each's `openFile` results.
- [ ] PB-M-6: quota-agent hook lands; both `Allocator.alloc` and `Fs.openFile` (and stream materialization caps) consult the same per-principal quota agent; refusal path returns `FSERR_QUOTA_EXCEEDED`.
- [ ] PB-M-9: cross-tenant Buffer→File composition is either explicitly allowed (documented) or rejected with FSERR_UNSUPPORTED (implemented).
- [ ] PB-M-10: `FSERR_REVOKED` re-request flow is either wired (with a documented policy interface) or explicitly deferred with a spec note.
- [ ] PB-M-11: spec §867 membrane-isolation claim is testable: Alice wraps her File in a membrane, Bob looks up the shared name via HIS Fs, receives a distinct File (NOT Alice's), cannot bypass the membrane.
- [ ] PB-M-12: consensus vs oracular mode routing lands. Test: two principals configured in different modes see the corresponding handler behavior (`chown` succeeds in Oracular, `FSERR_UNSUPPORTED` in Consensus).
- [ ] R-13 consensus-static routing: `consensus-static-*` config entries produce Fs caps whose native handlers are field-omitting.
- [ ] R-14 `sys:ui` gating: `--enable-ui-picker` flag observable in the powerbox handout policy; caps returned only in interactive use cases.
- [ ] R-15 URN wildcard resolution: both `` `rho:io:fs:1.0.0` `` and `` `rho:io:fs:1.*` `` resolve via the powerbox to a per-principal cap.

**Documentation / hygiene:**
- [ ] fs_genesis.rs §MVP simplifications #1-#5 are updated to reflect what the powerbox slice actually did.
- [ ] `rho_runtime.rs:783-786` docstring is updated to describe the current enforcement mechanism.
- [ ] PB-m-1: `rho:io:fs:native:*` URN scheme either formalized in spec or renamed to make internal-only status obvious.
- [ ] PB-m-2: Fs constructor fd args validated at powerbox boundary (Int type-guard).
- [ ] PB-m-5: stub-vs-real powerbox transition boundary documented in the powerbox module docstring.

## 8. Not in scope for the powerbox slice

- Runtime-level pathmap ACLs (Phase 8 concurrency).
- Consensus-mode replay determinism (spec §Consensus deployment).
- Legacy `rho:io:stdout` / `rho:io:stderr` shim maintenance (slice 20).
- Range-locks / `{"wait": true}` (Phase 8) — but note: Phase 8 adds two new `rho:io:fs:native:1.0.0/{lockRange,releaseLock}` URNs to the same filter surface that PB-B-1 governs. Whatever fix restores the URN filter must automatically cover these new URNs too (add to the prefix filter, not a per-URN allowlist).
- Cost accounting per principal (Phase 9) — quota-agent hook (PB-M-6) is the interface layer; per-principal phlogiston accounting is Phase 9's problem.
- Example scripts that exercise the powerbox (Phase 10 `fileio_cross_fs_isolation.rho`, `fileio_membrane.rho`) — these run against whatever powerbox exists at their landing, not scoped to the powerbox slice itself.

## Revision log

- 2026-07-28 — initial version. Consolidated Phase 6 slice-16..19 deferrals + spec §842-869 requirements. Author: Claude via slice-19 review synthesis.
- 2026-07-28 — added prior-phase surface: Phase 1 (native syscall trust in `root`, shared fd table), Phase 3 (allocator per-principal handout, quota-agent hook, Allocator scope), Phase 4 (Stream inheriting scope), Phase 5 (File/Dir canonRoot trust, cross-tenant Buffer↔File composition), plus revocation flow (PB-M-10) and stub-vs-real transition (PB-m-5). Added requirements R-7 through R-12 covering the allocator, quota agent, revocation, ambient-authority rationale, interim-stub semantics, and Phase 7 bundle handoff.
- 2026-07-28 — completeness pass: added R-13 (consensus/oracular mode routing), R-14 (`sys:ui` picker gating), R-15 (URN wildcard resolution); added PB-M-11 (spec §867 membrane-isolation claim currently false under shared-Fs), PB-M-12 (consensus-vs-oracular mode routing); added design questions Q-7 (mode assignment) and Q-8 (config-schema evolution); clarified R-9 vs `BUFERR_REVOKED` distinction; cross-referenced spec §Deferred "Cross-deployment agent lifetime" from Q-6.
