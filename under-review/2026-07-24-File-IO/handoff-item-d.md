# Session pickup — item (d): two-validator PB-M-14 E2E

You're picking up the `fileio-phase-1-2` branch of f1r3node-rust at
`/Users/stay/greg/f1r3fly/f1r3node-rust`.  Rust toolchain pinned to
`nightly-2026-02-09` via `rust-toolchain.toml`; prefix every cargo
command with `PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09`
(see auto-memory `f1r3node_toolchain.md`).

## Head as of handoff

- Code: `0d046ca87 fix(fileio): Phase 7b-2 item (c) hardening —
  Result-based applier + subscriber resilience` on `fileio-phase-1-2` in
  `/Users/stay/greg/f1r3fly/f1r3node-rust`.
- Docs: `4ea808b docs(plan): Phase 7b-2 item (c) landed (9aae8a722)`
  on `main` in `/Users/stay/greg/f1r3fly/FIPS/fileio`.

## Recently landed (last two commits)

- `9aae8a722` — Phase 7b-2 item (c) shipped end-to-end: applier moved
  from `fs_wal_spec.rs` test module to
  `rholang/src/rust/interpreter/io/wal_applier.rs` (c-1); boot
  enumerator + apply-to-follower via new
  `casper/src/rust/engine/wal_apply_boot.rs` + `decode_wal_slice` in
  `snapshot.rs` + `apply_wal_slice_after_fetch` in
  `wal_payload_sync.rs` + `SnapshotChunkSyncDriver::install_completion_sink`
  in `snapshot_chunk_sync.rs` (c-2); DD-7b-3 (a) `WalPayloadTickStop`
  handle on `WalPayloadContext.tick_stop` for graceful periodic-tick
  shutdown (c-3).  14 files, +1901/-229.
- `0d046ca87` — Phase 7b-2 item (c) hardening pass.  Applier now
  `Result<(), ApplierError>`-based with 13 named variants (no more
  panic-based invariant checks); `getpwnam_r`/`getgrnam_r` swap;
  NULL-byte-in-path caught cleanly; `allowed_roots: &[PathBuf]`
  defense-in-depth threaded through the applier → `apply_wal_slice_after_fetch`
  → `spawn_boot_apply_subscriber`; `BootApplyError::ApplierPanic`
  catches any `spawn_blocking` panic so the subscriber loop can't be
  killed.  16 new pins.  Boot sites in `casper_launch.rs` +
  `initializing.rs` currently pass `Vec::new()` for `allowed_roots`
  with a `TODO(fileio)` to plumb the operator's consensus-static
  roots — see the c-2 follow-up section below.

## Where to start

Read the session summary block first: `FIPS/fileio/under-review/2026-07-24-File-IO/implementation-plan.md`,
search for `Session summary — 2026-08-28 (head \`9aae8a722\`)`.
Then the `pb_m_14_two_validator_scaffold` ignored test at
`rholang/tests/fs_wal_spec.rs:4166-4220` — its docstring
enumerates the specific `TestNode` / `GenesisBuilder` gaps the last
session confirmed still hold.

## Task for this session — item (d): two-validator PB-M-14 E2E

Item (d) closes the two-validator end-to-end pin for PB-M-14
(file-state-identity).  Runtime-level pins already cover the WAL
byte-identity and applier-based reconstruction (see interim coverage
section in the plan doc's Phase 7 open items).  What item (d) adds is
exercising the property through `MultiParentCasperImpl::add_block` →
`validate_block` → `replay_deploys_for_state`, so a divergence between
production block-processing and the test-only `RhoRuntimeImpl::evaluate`
loop would surface here first.

**Full-context problem statement, not a recipe.**

The last session (2026-08-28) started implementing (d) and bailed
after confirming TestNode's dependency graph is deeper than the
initial estimate.  Concretely:

- `casper/tests/helper/test_node.rs::create_node` is 240+ LOC with
  wired-up state; every parameter added ripples through `network()`
  → `create_network*` (5 public entry points).  Every existing test
  either takes a new arg or needs a `_with_fs_provisioning` variant.
- `set_fs_snapshot_writer` + `set_payload_store` need snapshot_dir
  + payload_dir per node (or shared), mirroring
  `node/src/rust/runtime/setup.rs:245-395`'s ~90 LOC of
  provisioning-to-writer plumbing.
- The Casper-level replay path in `spawn_replay_runtime` (called
  from `MultiParentCasperImpl::validate_block`) is separate from
  `spawn_runtime` — B's replay-runtime WAL is what needs to match
  A's play-runtime WAL.  Verifying that at Casper level requires
  TestNode exposing per-runtime WAL snapshots, which no existing
  test needs.

Realistic sizing: 400-700 LOC across TestNode retrofit +
GenesisBuilder addition + the actual test.  1-2 sessions depending
on how the RuntimeManager provisioning wiring in TestNode uncovers
surprises.

## Load-bearing design decision — ASK USER BEFORE IMPLEMENTING

**Shared-fs or per-node fs?**  The last session bailed partly
because this wasn't nailed down first.  Options:

- **(A) Shared-fs** — both TestNodes point at the same on-disk
  tempdir.  WAL byte-identity across nodes is trivial (canon paths
  are identical).  The test exercises Casper propagation + replay.
  Does NOT verify "isolated validators produce the same on-disk
  state" — file-state-identity is a tautology because the file is
  literal-same on disk.
- **(B) Per-node fs with path_map** — each node has its own
  consensus-static root; the WAL applier's existing `path_map`
  closure remaps A's paths onto B's tree.  Problem: the Casper-level
  replay path doesn't currently invoke `apply_wal_to_fresh_tree` —
  replay re-executes the deploy and the fs handlers write to
  canonical paths directly.  Threading path_map through replay is
  a large architectural change.
- **(C) Per-node fs with logical-bucket-key canonicalization** —
  strip the operator-frozen root prefix so the WAL entry encodes
  the bucket key rather than the absolute path.  Hard-fork surface
  change (see `snapshot.rs`'s hard-fork catalog item #8 on path
  encoding).  Not attempted lightly.

**Recommended: (A) shared-fs.**  Rationale: minimal harness surface,
exercises the actual Casper propagation gap, and the "shared fs is
a tautology" concern is documented as a follow-up if isolation
testing becomes a priority.  Consensus impact: zero (test-only
shape).  BUT confirm this with the user before writing code — the
last session found the shared-fs approach acceptable but wanted
explicit sign-off.

## Load-bearing files to know about

- `rholang/tests/fs_wal_spec.rs:4166` — `pb_m_14_two_validator_scaffold`
  (ignored).  Docstring at lines 4166-4220 documents the harness
  gaps.  Remove `#[ignore]` when the harness lands.
- `casper/tests/helper/test_node.rs` — `TestNode` struct (line 56)
  + `create_node` (line 948) + `create_network*` (779, 800, 838).
  The retrofit target.
- `casper/tests/util/genesis_builder.rs` — `GenesisBuilder` (line
  80) + `build_genesis_parameters` (line 190).  Add
  `.with_fs_bundle(bundle)` builder setter + thread through
  `do_build_genesis`.  `Genesis.fs_bundle` at line 264 is currently
  `Vec::new()`.
- `casper/tests/genesis/contracts/fileio_fs_spec.rs:45-72` —
  `bundle_file` helper shows how existing tests inject an fs bundle
  via `params.2.fs_bundle = vec![entry]`.  Not a builder but the
  same mechanism.  Reuse the pattern or upgrade to a builder call.
- `node/src/rust/runtime/setup.rs:245-395` — the production fs
  boot pipeline.  TestNode's fs provisioning must mirror this:
  (a) `build_snapshot_writer(&merged, cadence, snapshot_dir, retain, signer_sk, payload_dir_for_retention)`;
  (b) `runtime_manager.set_fs_snapshot_writer(writer)`;
  (c) `PayloadStoreBundle::from_directory(DirectoryPayloadStore::new(payload_dir))`;
  (d) `runtime_manager.set_payload_store(Some(bundle))`.
- `rholang/src/rust/interpreter/io/wal_applier.rs` — production
  applier post-hardening.  Signature is
  `apply_wal_to_fresh_tree<F>(wal, payload_bytes, path_map,
  allowed_roots) -> Result<(), ApplierError>`.  If item (d) chooses
  option (B) per-node-fs, this is where path_map plumbing lives.
- `casper/src/rust/engine/wal_apply_boot.rs` — boot subscriber.
  If item (d) exercises the snapshot-fetch flow (Phase 7b-1 →
  Phase 7b-2 chain), this is where a Casper-level integration test
  would drive completions through.  For a pure block-propagation
  test (option A), the boot subscriber is not exercised.
- `casper/src/rust/util/rholang/runtime_manager.rs:490` —
  `spawn_runtime` where snapshot writer + payload store get shared
  into each spawned runtime.  `spawn_replay_runtime` at 555 is the
  companion for replay.

## Deferred / adjacent work discovered by the last session

- **`allowed_roots` production plumbing.**  Boot sites at
  `casper_launch.rs` and `initializing.rs` currently pass
  `Vec::new()` (validation skipped) with a `TODO(fileio)` comment.
  Threading the operator's consensus-static roots from provisioning
  config → boot-subscriber `allowed_roots` is a bounded slice
  (~30-50 LOC) that would close the defense-in-depth gap the c-2
  security review flagged.  Not required for item (d) but a
  natural pairing if either falls into scope together.
- **Live write-payload-determinism reducer.**  DD-7b-2 (a) reducer
  signature landed but callers pass `|_| None`.  A specific
  reducer + caller (e.g., deploy-arg reproduction from block
  storage) is future work.
- **Block-processing catch-up detector → `tick_stop.stop()`.**
  DD-7b-3 (a) plumbing is in place; the detector that raises the
  signal doesn't yet exist.  Also future work.

## Recommended session shape

Item (d) is genuinely multi-session.  Sensible single-session slice:

1. Land `GenesisBuilder::with_fs_bundle(bundle)` +
   `TestNode::create_node` extended with
   `Option<TestFsProvisioning>` (where `TestFsProvisioning =
   { data_dir, snapshot_dir, cadence, retain }`).  Wire
   `set_fs_snapshot_writer` + `set_payload_store` on RuntimeManager
   when Some.  All existing tests keep passing without changes
   (they get `None`).
2. Add ONE canary test at
   `rholang/tests/fs_wal_spec.rs::pb_m_14_two_validator_e2e` (or a
   new `casper/tests/pb_m_14_two_validator_spec.rs` for Casper-
   level pins): two-node network, shared tempdir, A submits a
   Consensus fs write deploy, propagate to B, assert both nodes'
   WAL slices are byte-identical + on-disk file matches expected
   bytes.
3. Defer additional Casper-level fs pins (multi-deploy, mixed
   Consensus + Oracular, cross-block finalization, snapshot-fetch
   flow via `wal_apply_boot`) to follow-up sessions.

If step 1 alone lands cleanly and step 2 slips scope, that's still
progress — the harness retrofit unblocks every future Casper-level
fs test.

## Test suites you'll want green at the end

Pre-work baseline (from the 2026-08-28 hardening pass):

- fs_wal_spec 58/58 (58 + 1 ignored `pb_m_14_two_validator_scaffold`)
- rholang lib io:: 312/312
- rholang lib (full) 702/702
- casper lib engine::wal_payload_sync 25/25
- casper lib engine::wal_apply_boot 4/4
- casper lib engine::snapshot_chunk_sync 14/14
- casper lib (full) 696/696
- snapshot_config 28/28
- payload_store_wiring 6/6, snapshot_writer_wiring 4/4

Post-session (if step 1 + step 2 land):

- fs_wal_spec 59/59 (unignore + implement `pb_m_14_two_validator_scaffold`
  or add a new sibling test)
- casper lib should stay at 696/696 or grow — any regression in
  the TestNode-touching tests is a load-bearing signal
- Everything else unchanged

## Commit hygiene

Pre-commit hook: `SKIP_FMT=1 SKIP_CLIPPY=1 SKIP_TESTS=1 git commit ...`.
NEVER `--no-verify` — that skips `deny` which is the real check.

## Review before commit

See auto-memory `feedback_review_before_commit.md`.  After tests are
green, pause for a security + coverage review; report findings
inline; then commit.

## Explicit first ask to the user

Before writing any code:

1. Confirm the design decision — **shared-fs (A), per-node with path_map
   (B), or per-node with bucket-key encoding (C)?**  Recommendation is
   (A) shared-fs; get sign-off first.
2. Confirm session slice — **step 1 only (harness retrofit) or step 1 +
   step 2 (harness + canary test)?**  Recommendation is step 1 + step 2
   if the harness lands cleanly early; otherwise step 1 alone and defer
   step 2.
