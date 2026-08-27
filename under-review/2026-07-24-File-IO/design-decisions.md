# File I/O — outstanding design decisions

**Opened:** 2026-08-27
**Last updated:** 2026-08-27 — DD-7b-1, DD-7b-2, DD-7b-3, DD-Dir,
DD-Waiters, DD-ReadLineInto **committed** by user sign-off.  DD-7b-3 +
DD-ReadLineInto diverged from documented leans.  DD-Waiters-XD remains
open.  Each committed entry now has "Decision (committed YYYY-MM-DD)"
in place of the "Lean (not committed)" line.
**Purpose:** consolidated surface for open design decisions that need
resolution before their downstream implementation slices can land.
A fresh session should read this alongside `implementation-plan.md`'s
"Unblocked next-step candidates" section — most "what should I decide
first?" questions resolve here.

Each entry:
- **Context** — why the decision matters + what depends on it.
- **Options** — enumerated with tradeoffs.
- **Lean / Decision** — either a "not committed" best guess or, if
  signed off, "committed YYYY-MM-DD" with the choice locked in.
- **Downstream** — implementation slices that unblock once decided.

---

## DD-7b-1 — Payload store location + retention

**Context.** The Phase 7b-2 `WalPayloadContext` currently instantiates
`InMemoryPayloadStore::new()` at every boot site (`casper_launch`,
`initializing`, `genesis_ceremony_master`).  Consequence: on process
restart, the store is empty and we're joiner-only; peers asking for
payloads get `UnknownPayload`.  For serving-validator behavior we need
persistent storage.

**Options.**

- **(a) Sibling dir** — `<node-dir>/wal_payload_store/<hex(hash)>`.
  Fits the shape of `DirectoryPayloadStore` already in
  `wal_payload_server.rs`.  Independent of snapshot dir → clean
  lifecycle isolation.
- **(b) Under snapshot dir** — `<snapshot-dir>/payloads/<hex(hash)>`.
  One operator-visible root; retention config could piggyback on
  `storage.consensus-fs-snapshot-retain`.  Tighter coupling; a snapshot
  cleanup can accidentally delete live payloads.
- **(c) Content-addressed inside the WAL directory** — payload bytes
  live next to the WAL journal.  Reuses WAL retention; but WAL append
  and payload store have different write patterns (append-only vs.
  content-addressed put-once).

**Retention shape.**

- **(x) Forever** — simple; unbounded disk growth.
- **(y) Match snapshot retention** — cleanup once every retained
  snapshot ≥ payload's referencing block.  Bounded; needs a scan.
- **(z) Time-based** — cleanup after `T` hours.  Simple; may delete
  payloads still needed by lagging joiners.

**Decision (committed 2026-08-27).**  **(a) + (y)** — sibling dir under
`<node-dir>/wal_payload_store/`, retention = one snapshot cycle behind
the earliest retained snapshot.  Rationale: dir lifecycle stays
independent (snapshot cleanup can't accidentally kill payloads); (y)
matches the "bytes needed to reconstruct any block between the earliest
retained snapshot and head" invariant from the plan's Phase 7b
retention discussion.

**Landed (a):** `4b1c19102` — see implementation-plan.md 7b-2 item (b).

**Landed (y):** `4b54de853` — sidecar-based union.  Each snapshot
write drops a `<hex(root)>.hashes` sidecar alongside its `.wal`
file (format: `[u32-be count][32-byte hash × count]`).  Finalization
runner runs `scan_retained_payload_hashes(snapshot_dir)` (unions
all sidecars) + `prune_payload_store(payload_dir, keep)` after
each successful `maybe_write`.  See implementation-plan.md 7b-2
retention entry.

**Downstream.**
- 7b-2 follow-up **(b)** — populating the store from fs_write handlers.

---

## DD-7b-2 — Reducer API shape

**Context.** `enumerate_and_enqueue_payloads` takes an
`is_reproducible: Fn(&[u8; 32]) -> bool` predicate; every caller passes
`|_| false`.  The write-payload-determinism reducer should let the
joiner skip fetching bytes it can reproduce locally.  Current signature
doesn't get enough context — you can't reproduce bytes from just their
hash.

**Options.**

- **(a) `Fn(&WalEntry) -> Option<Vec<u8>>`** — reducer returns bytes if
  it can produce them.  `Some` → skip fetch, apply locally; `None` →
  enqueue fetch.  Signature carries all the entry context (op, path,
  offset, deploy-scope reference) the reducer needs.
- **(b) Split methods** — `is_reproducible(&WalEntry) -> bool` +
  separate `reproduce(&WalEntry) -> Vec<u8>`.  Cleaner separation of
  "can we?" vs. "do it."  Doubles the caller surface.
- **(c) Async trait** — `async fn reproduce(&self, entry: &WalEntry) ->
  Option<Vec<u8>>`.  Fits future needs (e.g., loading deploy data from
  block storage) but adds async surface to a hot-loop enumerator.

**Blocking question.**  Does the joiner BLOCK on reducer output
(deterministic, cheap) or fall back to network fetch (async, expensive)
if the reducer returns `None`?  Current design: fall back always.  If
the reducer becomes async (option c), the enumeration loop itself
becomes async.

**Decision (committed 2026-08-27).**  **(a)** synchronous
`Fn(&WalEntry) -> Option<Vec<u8>>`.  Simplest API; the reducer's inputs
are all in-memory (deploy data + Rholang term).  Async can come later
if a specific reducer needs it.

**Downstream.**
- 7b-2 follow-up **(a)** — wiring the reducer at boot enumeration.

---

## DD-7b-3 — Sync completion signal

**Context.** `spawn_periodic_tick` loops forever.  Once the joiner has
caught up to head, we want the retriever + sync driver to shut down.
Currently no signal terminates the loop.

**Options.**

- **(a) Explicit `driver.stop()`** called when block-processing catches
  head.  Simple; requires the block-processing loop to know about the
  driver.
- **(b) Cancellation token** — pass a `CancellationToken` (or
  `tokio_util::sync::CancellationToken`) into `spawn_periodic_tick`;
  block-processing cancels it.
- **(c) Leave as-is; stale-eviction drains.**  If no new payloads are
  enqueued for `STALE_EVICTION_MS`, the retriever gradually empties.
  Tick continues to fire every 5s but does no useful work.  Low overhead
  (eviction pass + empty pending set = ~1ms per tick).

**Decision (committed 2026-08-27).**  **(a)** explicit `driver.stop()`
called when block-processing catches head.  Diverges from the earlier
lean of (c) — user opted for explicit shutdown plumbing over drain-by-
stale-eviction.  Rationale for the override: keeps the runtime shape
observable ("is the retriever alive?"), avoids "why is this timer still
firing?" confusion, and the extra wiring is a one-shot signal from the
block-processing loop — small blast radius.

**Downstream.**
- 7b-2 follow-up **(c)** — boot enumerator wiring.

---

## DD-Dir — Dir-fd deploy-end sweep coupling

**Context.** `DirHandleTable::close_all_for_deploy` exists at
`rholang/src/rust/interpreter/io/dir_handle_table.rs:356` but is NOT
wired into `WalDeployScope::Drop`.  Consequence: Rholang deploys that
open `Dir.entries()` streams and drop the Stream cap before EOS hold
dir fds until runtime respawn.  Under adversarial Rholang, an attacker
pins all 1024 dir fds within one block and DoS's subsequent dir-list
operations.

**Options.**

- **(a) Unify with file-fd sweep** — one code path in
  `WalDeployScope::Drop` handles both file + dir tables.  Requires a
  `HandleKind` enum tag on the handle-table entry.  Clean; slight
  divergence of `FileHandle` and `DirHandle` under the sweep abstraction.
- **(b) Separate `sweep_dirs` sibling** — parallel method next to the
  file sweep.  Duplicates the drain loop; keeps each handle-table
  self-contained.
- **(c) Sync-Drop that `block_on`s the async close** — foot-gun if a
  caller drops from an async context.

**Blocking question — async-in-sync-Drop.**  Both tables' close is
async (WAL flush).  The lock-sweep is sync.  How does the async close
run from `Drop`?  Existing options:
- `tokio::runtime::Handle::current().block_on(...)` — works if we're in
  a tokio runtime and NOT already blocking.
- Post the close to a background reaper task via mpsc.  Simpler; adds a
  named background task to the runtime shape.

**Decision (committed 2026-08-27).**  **(a)** unified sweep, **(b')**
background reaper for the async close.  Rationale: (a) is one code path
for the operator to reason about; (b') avoids the block_on foot-gun.

**Downstream.**
- Dir-stream fd deploy-end sweep implementation slice.

---

## DD-Waiters — `MAX_WAITERS_PER_FILE` cap threshold + overflow semantics

**Context.**  Prevents a runaway deploy from queueing unbounded waiters
against a single lock.  Legit concurrency is probably ~32; DoS floor is
much higher.

**Options.**

- **Threshold values.**  32 (tight; may reject legit patterns), 256
  (comfortable), 4096 (permissive).
- **Overflow semantics.**  (i) silent reject with `Err`; (ii) fail-closed
  on the file until a waiter clears; (iii) return `FSERR_QUOTA_EXCEEDED`
  (surfaced to Rholang caller).

**Decision (committed 2026-08-27).**  **256 + (iii)**.  Rationale: 256 is
well above legit workloads; surfacing the error to Rholang lets
contracts adapt (retry with backoff).  Hard-fork surface (rejection code
path change).

**Downstream.**
- Phase 8 review follow-up NB-3 slice.

---

## DD-Powerbox — Powerbox stub scope

**Context.**  Phase 10e (`fileio_cross_fs_isolation.rho`) needs a
Powerbox to gate cross-root access, but the full Powerbox capability
system is a separate epic.

**Options.**

- **(a) Minimal viable stub** — a single global registry mapping
  `SystemName → FS_ROOT`; rejects opens outside the registered root.
  Enough to write the isolation test.  NOT enough to ship.
- **(b) Per-deployerId Powerbox** (Phase 6 deliverable that wasn't
  built).  Larger scope; ships a real capability layer.
- **(c) Wait until the Powerbox epic starts.**  Blocks Phase 10e
  indefinitely.

**Lean (not committed).**  **(a)** with explicit "stub — not for
production" markers.  Rationale: unblocks 10e without committing to the
full capability system; the isolation test's assertions are the
minimum-viable interface anyway.

**Downstream.**
- Phase 10e `fileio_cross_fs_isolation.rho`.
- `fileio_membrane.rho` example.

---

## DD-ReadLineInto — `readLineInto` arity-N+1 wait-variants

**Context.**  The current handler has `wait:true`/`wait:false` as a bool
arg.  Question is whether we split into separate rho methods or keep
the bool.

**Options.**

- **(a) Split** — `readLineInto` (no wait) and `readLineIntoWaiting`
  (wait) as separate rho methods.  Uniform with how `lockRange` shapes
  are exposed.  Doubles the callsite surface.
- **(b) Keep the bool** — one method, one bool arg.  Less churn.  Bool
  is easy to typo.

**Decision (committed 2026-08-27).**  **(a)** — split into
`readLineInto` (no wait) and `readLineIntoWaiting` (wait) as separate
rho methods.  Diverges from the earlier lean of (b) — user opted for
uniform shape with `lockRange`.  Rationale for the override: matches
the wait-variant shape already used by `lockRange`; bool-arg typos are
worse than callsite duplication for a wait-vs-nowait distinction that
callers should be aware of.  Hard-fork surface (new native URN).

**Downstream.**
- Phase 8 review follow-up (readLineInto arity-N+1 wait-variants).

---

## DD-Waiters-XD — Cross-deploy mutual-wait deadlock

**Context.**  Phase 8 review NB-7: deploy A waits on a lock held by
deploy B; deploy B waits on a lock held by deploy A.  Under Phase 8
semantics both deploys wait forever until the block's deploy budget
exhausts.

**Options.**

- **(a) Deadlock detection** — cycle-detect the wait-for graph before
  each acquire.  Precise; O(V+E) per acquire under adversarial patterns.
- **(b) Per-deploy timeout** — deploys automatically fail after
  `T` seconds waiting.  Simple; sets a non-consensus semantic hard
  bound.
- **(c) Prohibit cross-deploy waits** — reject any wait that would
  touch a lock outside the current deploy's scope.  Simplest; may reject
  legit patterns.

**Lean (not committed).**  Needs more design input — this is genuinely
subtle and interacts with the WAL boundary shape.  Defer to a dedicated
design session.

**Downstream.**
- Phase 8 review follow-up NB-7 slice.
