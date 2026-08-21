# Merge `feature/cost-accounted-rho` into `fileio-phase-1-2` — resumption plan

**Date opened**: 2026-08-21
**Context**: Previous session attempted the merge; hit an architectural
incompatibility. This document contains the concrete plan to finish it correctly.

---

## Session-crossing context

### Branches involved

| Branch | Role | Origin tip (as of 2026-08-21) |
|---|---|---|
| `fileio-phase-1-2` | Fileio Phase 1-10 work. 103 commits ahead of master. | `7d946e4c` |
| `feature/cost-accounted-rho` | Authoritative cost-accounting model. 682 commits ahead of master. | `c60b55ce6` |
| `merge/cost-accounting-into-fileio` | **WIP** scratch merge branch (this doc's target). | `3546e0ea7` (merge commit — see below) |

**Common ancestor**: `814fa3121` "Merge branch 'master' into dev"

**Repo path**: `/Users/stay/greg/f1r3fly/f1r3node-rust`

### Current state of the merge branch

`merge/cost-accounting-into-fileio` @ `3546e0ea7` is a WIP merge commit that:
- Contains ALL 12 textual conflict resolutions (already done — do not redo).
- Does NOT compile: 14 errors, all in ONE method
  (`casper/src/rust/rholang/runtime.rs::play_deploy_with_cost_accounting`).
- Reason: cost-accounted-rho removed the pre-charge/refund model
  (`system_deploy_util::generate_*_seed`, `DeployData::total_phlo_charge()`,
  `ProcessedDeploy::refund_amount()`, `PreChargeDeploy`/`RefundDeploy` structs,
  `EvalCollector`) that fileio's WAL-boundary method was layered on top of.
- Cost-accounted's model is authoritative — we adopt its shape and rewrite
  fileio's WAL-boundary machinery on top of cost-accounted's atomic-deploy
  boundary (the soft-checkpoint in
  `process_deploy_cosigned_with_budget_and_authority_mode`).

### Conflict resolutions already applied (do not redo)

See the merge commit message on `3546e0ea7` for the full list. Highlights:

- `Cargo.toml`, `node/Cargo.toml`, `Cargo.lock` — dep-bump reconciliation
  (took cost-accounted's `rholang-parser` rev pin `02cef80`; kept both
  `tempfile` + `proptest` dev-deps).
- `casper/src/rust/genesis/contracts/embedded_rho.rs` — kept both `.rho` +
  `.rhox` include_str! declarations (orthogonal).
- `casper/src/rust/genesis/contracts/standard_deploys.rs` — kept both PK/
  timestamp/PUB_KEY sets (`FS_GENERATOR_*` + `CAPABILITIES_REGISTRY_*` +
  `EXCHANGE_*`).
- `casper/src/rust/engine/block_approver_protocol.rs` — use `&funded_vaults`
  (cost-accounted's vault-funding transform) + kept fileio's `fs_bundle` +
  `consensus_fs_snapshot_cadence` args.
- `casper/src/rust/reporting_casper.rs` — replaced `!with_cost_accounting`
  with `block_kind == ReplayBlockKind::Genesis`; kept fileio's URN filter
  exemption + cost-accounted's terminal-close validation.
- `casper/src/rust/rholang/replay_runtime.rs` — same `block_kind` swap;
  kept fileio's `WalDeployScope` wrapper + adopted cost-accounted's
  `process_ordinary_deploy` dispatch.
- `casper/src/rust/rholang/runtime.rs` (3 regions) — merged fileio's WAL
  aggregation with cost-accounted's per-deploy checkpoint chain; kept BOTH
  `play_deploy_with_cost_accounting` (the un-compilable one — DELETE per
  step 1 below) AND `play_ordinary_deploy`.
- `casper/src/rust/util/rholang/runtime_manager.rs` (2 regions) — kept
  cost-accounted's `evict_block_index_entry` + `record_block_index_cache_metrics`
  methods AND fileio's `H-7 note` docstring; kept both test modules
  (`snapshot_writer_wiring_tests` + cost-accounted's `tests`) as separate
  `#[cfg(test)] mod` blocks.
- `rholang/src/rust/interpreter/rho_runtime.rs` (3 regions) — kept fileio's
  URN filter methods (`enable/disable/exempt/introspect`) AND cost-accounted's
  `clear_cost_event_log`/`evaluate_with_authority`; merged `setup_reducer`
  signature (adopted `RuntimeBudget` + `metering.clone()` +
  `Substitute { metering }`; kept fileio's `fs_handles`/`fs_mode` params +
  `filter_fs_native_urns` field).
- `rholang/src/rust/interpreter/reduce.rs` (2 regions) — pre-computed URN
  filter check hoisted from removed `alloc` closure into a pre-
  `allocate_new_bindings` check; adopted `metering.reserve_reduction`;
  migrated 3 sites from `self.outer.cost.charge` to
  `self.outer.metering.reserve_primitive`.

---

## What must be preserved: `WalDeployScope` invariants

Defined at `casper/src/rust/rholang/runtime.rs:280-441`. Three consensus-critical
invariants that the rewrite MUST preserve:

### 1. Discard-on-error boundary (RAII `Drop`)

If a deploy fails mid-flight, the scope's Drop drains and discards the failed
deploy's WAL contributions from `runtime.fs_handles.wal`. Prevents:
- WAL entries from a rolled-back deploy leaking into the next deploy's slice.
- Leader-vs-follower divergence based on where failures occurred.

Also releases the deploy's range-lock acquires from the shared `LockRegistry`
via `release_all_for_deploy(&deploy_scope)`.

### 2. Log-order canonicalization

`take_and_commit(deploy_log)` at line 390 walks the deploy's `event_log`
Produces to derive canonical order — not tokio-scheduler insertion order.
Byte-identical WAL slices across validators regardless of local
Par-scheduling nondeterminism.

### 3. Per-block aggregation

Successful deploys' slices concatenate; the aggregate `Vec<WalEntry>` is:
- Blake2b256-Merkle-rooted for the per-block consensus WAL commitment
  (slice 30b).
- Cached in `pending_wal_slices` keyed by post-state hash for
  finalization-runner snapshot cadence (slice 30c H-1).

---

## Cost-accounted's atomic-deploy boundary

`casper/src/rust/rholang/runtime.rs::process_deploy_cosigned_with_budget_and_authority_mode`
(line 1962). The **INNER soft-checkpoint** (line 1972) is the atomic-deploy
boundary:

```rust
// INNER soft-checkpoint — wraps the USER DEPLOY only.
// On a failed user deploy it reverts that deploy's effects
// (D3: no pre-charge state).
let fallback = self.runtime.create_soft_checkpoint().await;
let eval_result = /* evaluate_cosigned_with_budget_and_authority_mode */;
match eval_result {
    Ok(...) => { /* commit */ }
    Err(...) => {
        // Rollback to fallback — discards RSpace effects.
        Err(...)
    }
}
```

Soft-checkpoint rollback discards **RSpace state**. `WalDeployScope` discards
**WAL entries + lock acquires**. Semantically the same boundary — they should
share it.

---

## Integration plan: wrap `WalDeployScope` around the soft-checkpoint

Inside `process_deploy_cosigned_with_budget_and_authority_mode`, add a
`WalDeployScope` wrapper that opens BEFORE the soft-checkpoint and either
commits (on success, via `take_and_commit(&deploy_log)`) or auto-discards
(on failure, via RAII Drop):

```rust
async fn process_deploy_cosigned_with_budget_and_authority_mode(
    &mut self,
    cosigned: Cosigned<DeployData>,
    budget: Cost,
    authority_allocation: Option<ResourceMultiset<[u8; 32]>>,
    default_authority: DefaultCostAuthority,
    report_exhaustion: bool,
) -> Result<(ProcessedDeploy, HashMap<Par, MergeType>, Vec<WalEntry>, bool), CasperError> {
    // NEW: derive deploy scope from primary signer's signature.
    let deploy_scope: DeployScope = {
        // Verify: `Cosigned<DeployData>` API for extracting the primary
        // signer's sig.  Likely `cosigned.primary().sig` or
        // `cosigned.into_legacy_signed_unchecked().sig`.
        let sig = /* primary sig from cosigned */;
        let h = crypto::rust::hash::blake2b256::Blake2b256::hash(sig.to_vec());
        let mut arr = [0u8; 32];
        arr.copy_from_slice(&h);
        arr
    };
    let mut wal_scope = crate::rust::rholang::runtime::WalDeployScope::new_with_lock_sweep(
        self.runtime.fs_handles.wal.clone(),
        self.runtime.fs_handles.lock_registry.clone(),
        deploy_scope,
        self.runtime.fs_handles.current_deploy_scope.clone(),
    );

    // EXISTING: INNER soft-checkpoint.
    let fallback = self.runtime.create_soft_checkpoint().await;
    let eval_result = self.evaluate_cosigned_with_budget_and_authority_mode(
        &cosigned,
        budget,
        authority_allocation,
        default_authority,
    ).await;

    match eval_result {
        Ok((deploy_log, mergeable_data, exhausted, /* ... */)) => {
            // NEW: extract WAL in log order using deploy's event_log.
            let fs_wal = wal_scope.take_and_commit(&deploy_log);
            // EXISTING: build ProcessedDeploy.
            let processed = ProcessedDeploy { /* ... */ };
            Ok((processed, mergeable_data, fs_wal, exhausted))
        }
        Err(e) => {
            // EXISTING: soft-checkpoint rollback.
            // (Whatever the current code does — revert_to_soft_checkpoint or
            // equivalent.)
            // AUTO: WalDeployScope Drop discards WAL entries + lock acquires.
            Err(e)
        }
    }
}
```

Key point: the WalDeployScope is constructed BEFORE the soft-checkpoint so
that if the soft-checkpoint's own construction/rollback ever fails, the
WAL still gets cleaned up.

---

## API ripple: 3-tuple / 4-tuple through 5 layers

The `Vec<WalEntry>` needs to thread through the existing return-type chain:

| Method | Current return | New return |
|---|---|---|
| `process_deploy_cosigned_with_budget_and_authority_mode` | `(pd, mc, bool)` | `(pd, mc, Vec<WalEntry>, bool)` |
| `process_deploy_cosigned_with_budget_and_authority` | `(pd, mc, bool)` | `(pd, mc, Vec<WalEntry>, bool)` |
| `process_deploy_cosigned_with_budget` | `(pd, mc, bool)` | `(pd, mc, Vec<WalEntry>, bool)` |
| `process_deploy_cosigned` | `(pd, mc)` | `(pd, mc, Vec<WalEntry>)` (drops `exhausted`) |
| `play_ordinary_deploy_cosigned` | `(pd, mc)` | `(pd, mc, Vec<WalEntry>)` |
| `play_ordinary_deploy` | `(pd, mc)` | `(pd, mc, Vec<WalEntry>)` |

Grep verification:

```
grep -n "async fn process_deploy_cosigned\|pub async fn play_ordinary" \
    casper/src/rust/rholang/runtime.rs
```

Should return the 5-6 sites above.

### Callers to update

**`play_deploys_for_state` loop** (line ~1450 on the merge branch): my
previously-merged loop already accumulates `fs_wal` into a `block_fs_wal`
Vec. Change the call from `play_deploy_with_cost_accounting` (which is
being deleted per step 1 below) to `play_ordinary_deploy`. The 3rd tuple
element is `fs_wal` in both — mechanical.

**`play_deploys_for_genesis` loop** (line ~1547): same treatment.

**`replay_runtime.rs::replay_deploy_e`**: currently wraps a `WalDeployScope`
+ calls `process_deploy_with_cost_accounting` (fileio) OR
`process_ordinary_deploy` (cost-accounted). After the rewrite, it just
calls `play_ordinary_deploy_cosigned` and pulls `fs_wal` from the new
3-tuple. The explicit `WalDeployScope` wrapper in `replay_deploy_e`
can be REMOVED because it's now applied inside
`process_deploy_cosigned_with_budget_and_authority_mode`.

**`reporting_casper.rs`**: reporting doesn't commit WAL, so probably no
change needed. Verify by checking whether reporting calls
`process_deploy_cosigned` or one of its budget-taking variants.

**Test fixtures**: search for constructions of `ProcessedDeploy` alongside
expected 3-tuple returns. Update to expect `Vec::new()` for `fs_wal`.

---

## Implementation checklist

Numbered order matches suggested execution:

1. **Delete `play_deploy_with_cost_accounting` method** and its unused
   helpers. Located at `casper/src/rust/rholang/runtime.rs:1606-1841`
   (approximately). Also verify `EvalCollector` isn't used elsewhere —
   if it is, keep it; if not, delete it.

2. **Add `WalDeployScope` wrapper in
   `process_deploy_cosigned_with_budget_and_authority_mode`** at
   `casper/src/rust/rholang/runtime.rs:1962`. Insert scope creation
   BEFORE the soft-checkpoint (line ~1972); insert `take_and_commit(&deploy_log)`
   in the success arm.

3. **Extend 4-tuple return through internal chain**:
   `_with_budget_and_authority_mode` → `_with_budget_and_authority` →
   `_with_budget`. Threading `Vec<WalEntry>` through unchanged as new
   3rd element.

4. **Change `process_deploy_cosigned` to return 3-tuple**
   `(pd, mc, fs_wal)`. Discards `exhausted`.

5. **Change `play_ordinary_deploy_cosigned` + `play_ordinary_deploy` to
   return 3-tuple.** Propagate `fs_wal`.

6. **Update `play_deploys_for_state` loop** at line ~1450. Replace
   `play_deploy_with_cost_accounting(deploy).await?` with
   `play_ordinary_deploy(deploy).await?`; keep the fs_wal aggregation
   and checkpoint-chain tracking already merged.

7. **Update `play_deploys_for_genesis` loop** at line ~1547 — same pattern.

8. **Update `replay_runtime.rs::replay_deploy_e`**. Remove the explicit
   `WalDeployScope` wrapper (now inside
   `process_deploy_cosigned_with_budget_and_authority_mode`). Use the
   new 3-tuple return from `play_ordinary_deploy_cosigned`.

9. **Update `reporting_casper.rs`** if needed — probably not, since
   reporting doesn't commit WAL. Verify.

10. **Fix compile errors in test fixtures**. Search for constructions of
    `ProcessedDeploy` alongside 3-tuple returns. Add `Vec::new()` for
    `fs_wal` where synthetic returns are needed.

11. **Run full push checklist** — see "Verification" below.

12. **Fast-forward `fileio-phase-1-2` to the merge branch** once all
    green. Push.

---

## Verification (push checklist)

**Nightly toolchain gotcha** — the workspace requires
`nightly-2026-02-09` (per `rust-toolchain.toml`). MacPorts stable
`/opt/local/bin/cargo` doesn't read `rust-toolchain.toml`. Use:

```
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 cargo ...
```

Alternatively, prepend `$HOME/.cargo/bin` to PATH shell-wide.

### 1. Compile check first

```
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 \
    cargo check --workspace
```

Zero errors = merge integration is structurally sound. Iterate on step
10 (test fixtures) until this passes.

### 2. Highest-priority WAL tests (MUST pass)

```
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 \
    cargo test --package rholang --test fs_wal_spec
```

Target: 29 passing. If any fails, the WAL boundary is wrong — investigate
the specific test to understand which invariant was violated.

Also run any test with `WalDeployScope` in scope:

```
grep -rln "WalDeployScope" casper/tests/ rholang/tests/
```

### 3. fileio combined suite

```
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 \
    cargo test --package casper --test mod -- \
    'genesis::contracts::fileio_' 'genesis::contracts::fs_generator_spec'
```

Target: 39 passing, 2 ignored.

### 4. file_dir_check (mock-syscall integration)

```
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 \
    cargo test --package rholang --test file_dir_check --release
```

Target: 491 passing, 3 ignored. Long-running (~12 min); run in background.

### 5. fmt + clippy

```
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 \
    cargo fmt --all -- --check
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 \
    cargo clippy --all-targets -- -D warnings
```

### 6. Cost-accounting regression tests

Cost-accounted's own test suite runs against the merge branch too —
verify no regressions from the 3-tuple change:

```
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 \
    cargo test --workspace
```

---

## Success criteria

- Merge branch `merge/cost-accounting-into-fileio` at origin passes all
  6 verification steps.
- `fileio-phase-1-2` fast-forwarded to the merge branch and pushed.
- No new `#[ignore]` tests added to work around integration issues.

---

## Rollback plan

If the WAL integration proves intractable in reasonable time:

1. `git checkout fileio-phase-1-2` — reverts to pre-merge state
   (`7d946e4c` on origin).
2. `git branch -D merge/cost-accounting-into-fileio` (local); optionally
   `git push origin :merge/cost-accounting-into-fileio` (remote).
3. Consider a different strategy: **rebase fileio's fs slices on top of
   cost-accounted-rho** instead of merging. This is more surgical
   because cost-accounted's shape becomes canonical from the start,
   and fileio's WAL machinery is designed against it directly rather
   than adapted post-hoc.

Rebase strategy would take longer (few days) but might yield a cleaner
result. Only pursue if the merge integration proves ill-conditioned.

---

## Convenience references

**Blocked-out method to delete** (14 compile errors originate here):

`casper/src/rust/rholang/runtime.rs::play_deploy_with_cost_accounting`

**Integration target** (add WalDeployScope wrapper here):

`casper/src/rust/rholang/runtime.rs::process_deploy_cosigned_with_budget_and_authority_mode`

**WalDeployScope definition**:

`casper/src/rust/rholang/runtime.rs:280-441`

**Environment**:

- Working dir: `/Users/stay/greg/f1r3fly/f1r3node-rust`
- Current branch: `merge/cost-accounting-into-fileio` (WIP)
- Toolchain: nightly-2026-02-09 (rust-toolchain.toml)
- Cargo shim needed: `PATH="$HOME/.cargo/bin:$PATH"`
