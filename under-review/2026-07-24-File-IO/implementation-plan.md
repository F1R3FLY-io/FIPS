# File I/O — Implementation Plan

Companion to [`2026-07-24-File-IO.md`](./2026-07-24-File-IO.md).  Written 2026-07-25 against the streams-first + buffers-integrated spec (merged into FIPS `main` as commit `338c2132`; the FIP directory was subsequently redated to reflect the streams-first cut).  Supersedes the earlier method-centric plan.

## Scope

Implement the full FIP surface described by the current spec:

- `Stream` agent with `CharStream` / `ByteStream` / `EntryStream` / `LineStream` specializations, plus the six base combinators (`next`, `chunk`, `close`, `fold`, `foldChunks`, `forEach`) and the two parallel combinators (`foldConcurrent`, `mapReduce`).
- Fixed-size byte `Buffer` agent (§Buffers), with the allocator library at `rho:lang:buffer:1.0.0` and the buffer-of-buffers `Rows` agent.
- `File`, `Dir`, `Fs` agents; `Stdin` / `Stdout` wrappers.
- Static provisioning surface (config block + repeatable CLI flags), with boot-time symlink / hard-link rejection.
- Path quarantine per every path-taking method.
- Consensus-safe record-shape handling (host-transient fields omitted in consensus mode).
- Cost-accounting hooks wired even if constants are placeholder.

Non-goals:

- The follow-up items in §Deferred: cross-deployment agent lifetime, consensus-mode filesystem sync, general `Stream.map`/`filter`/`take`/`drop` combinators, `sync_data`-only `flush` variant, `entriesTree`, code-point-indexed buffer access, alternate encodings, `readLineInto` truncation-policy option, `byte_array_append_cost` linearization.
- Windows / BSD support.  Targets macOS + Linux.

## Prerequisites

Verify each is present on the `f1r3node-rust` main branch before starting Phase 1:

- **Versioned Registry** (approved) — `rho:lang:*:*` versioned URN lookup.  The allocator (`rho:lang:buffer:1.0.0`) and the `Fs` agent (`rho:io:fs:1.0.0`) both rely on this.
- **Agents** (approved) — `agent { constructor / method / default }` sugar, `!?` send-return, method-call sugar `x!m(args)`.  All four agent classes (`File`, `Dir`, `Fs`, `Buffer`) are `agent` blocks.
- **Private Methods** (approved) — `private method`, `private default`.  Used inside library agents for internal state helpers.
- **`try`/`catch` sugar** (approved) — the primary error-handling shape throughout the spec.
- **Numeric Types** (approved) — `u64`, `u8` types for offsets/sizes/byte values.
- **Reifying RSpaces** (approved) — precedent for keeping buffer bytes in the tuplespace.

Each is a hard blocker; the FIP text assumes their syntax freely.

## Companion FIPs (in draft)

- **Powerbox** — the delegation contract this FIP repeatedly assumes.  The `Fs` agent and the allocator are both handed out per-principal by the powerbox; the ocap-scoping guarantee (Alice's membrane isn't bypassable by Bob) rests on the powerbox handing distinct instances per grantee.  **Interim stub**: rather than "a single shared `Fs`", the genesis deploy publishes a stub Powerbox that mints one `Fs` instance per **authenticated `deployerId`** (extracted from `NormalizerEnv`'s `rho:deploy:data` + `rho:system:deployerId:ops`).  The URN semantics — `getFs(`rho:io:fs:1.0.0`)` returns a per-principal handle — are therefore stable across the Powerbox transition: only the *delegation policy* changes when the Powerbox FIP lands, not the client-side lookup shape.  Same treatment for the allocator (`rho:lang:buffer:1.0.0`): per-`deployerId` instance from the stub, upgraded to the real Powerbox's policy later.
- **Garbage Collection** — the deploy-end backstop that reclaims unreferenced buffer dispatchers, tombstones, and any unclosed chunks.  Not required for correctness of a single-deploy path, but required to reclaim leaked instances at deploy end.

## Architecture

Three layers, top-down:

### 1. Native primitives (Rust; f1r3node interpreter)

The syscall-and-decode bridge.  All primitives are:

- **Non-deterministic replay-wrapped** — `is_replay` guard at handler entry; on replay, produce the log's captured `previous_output` rather than re-issuing the syscall.
- **UTF-8-strict at String boundaries** — content-side UTF-8 failure returns `"FSERR_IO"`, not `"FSERR_BAD_ARG"`.
- **Fixed-channel-only** — URNs `rho:io:fs:native:1.0.0/*` are filtered out of the user-reachable `urn_map`.  The genesis `Fs`-agent deploy is the sole holder.
- **Cost-accounted** — `CostManager::charge()` at handler entry, proportional to work done.

Two families:

**Filesystem syscalls.**

| Native URN | Signature | Notes |
|---|---|---|
| `rho:io:fs:native:1.0.0/open` | `(pkHex: String, canonPath: String, mode: String) -> [true, fd] \| [false, code, msg]` | `symlink_metadata` first; reject non-regular files with `"FSERR_UNSUPPORTED"`.  Pass `O_NOFOLLOW` if the host supports it. |
| `.../close` | `(fd: u64) -> [true]` | Idempotent from the runtime's side; the agent-layer close checks first. |
| `.../read` | `(fd: u64, n: u64) -> [true, bytes]` | Advances position.  Cap: `MAX_READ_BYTES = 64 MiB` per call. |
| `.../readAt` | `(fd: u64, offset: u64, n: u64) -> [true, bytes]` | Positional; does not advance. |
| `.../write` | `(fd: u64, bytes: ByteArray) -> [true, nWritten]` | Full-buffer write; advances position. |
| `.../writeAt` | `(fd: u64, offset: u64, bytes: ByteArray) -> [true, nWritten]` | Positional. |
| `.../seek` | `(fd: u64, offset: i64, whence: String) -> [true, newPos]` | `whence ∈ {"set","cur","end"}`. |
| `.../tell` | `(fd: u64) -> [true, pos]` | |
| `.../size` | `(fd: u64) -> [true, nBytes]` | |
| `.../truncate` | `(fd: u64, n: u64) -> [true]` | Cap: `MAX_TRUNCATE_BYTES = 16 GiB` per call. |
| `.../flush` | `(fd: u64) -> [true]` | `sync_all` (data + metadata). |
| `.../stat` | `(canonPath: String) -> [true, record]` | `symlink_metadata`; consensus-mode field omission. |
| `.../exists` | `(canonPath: String) -> [true, Bool]` | `symlink_metadata`. |
| `.../entries` | `(canonPath: String) -> [true, listOfRecords]` | Sorted lex by name.  Streaming variant `.../entriesStream` deferred until stream-of-record wiring lands (Phase 4). |
| `.../rename` | `(fromCanon: String, toCanon: String) -> [true]` | `"FSERR_CROSS_DEVICE"` if cross-filesystem. |
| `.../copyFile` | `(fromCanon: String, toCanon: String) -> [true, nBytes]` | |
| `.../removeFile` | `(canonPath: String) -> [true]` | |
| `.../removeDir` | `(canonPath: String, recursive: Bool) -> [true]` | |
| `.../chmod` | `(canonPath: String, modeBits: u64) -> [true]` | Bits in `0..=511`; agent layer parses `"rwxr-xr-x"`.  `fchmodat(AT_SYMLINK_NOFOLLOW)`. |
| `.../chown` | `(canonPath: String, owner: String, group: String) -> [true]` | `Nil` for "don't change".  `lchown`.  `"FSERR_UNSUPPORTED"` in consensus mode. |
| `.../quarantine` | `(rootCanon: String, rel: String) -> [true, canonPath]` | Canonicalize + escape-check.  Reject empty / root-self / above-root. |

**Path quarantine location.**  Every path-taking native takes `(rootCanon, rel)` and quarantines internally — collapses the two-message check-then-syscall window to a single call.  `quarantine` remains as a standalone check for the `openFile`/`openDir` bundle flow (where the caller needs the canonical path back to construct a downstream agent).

**Buffer helpers.**

| Native method | Signature | Notes |
|---|---|---|
| `"validUtf8PrefixLen"` on `ByteArray` | `ByteArray -> u64` | Longest valid-UTF-8 prefix.  Total; never raises. |
| `"decodeUtf8"` on `ByteArray` | `ByteArray -> String` | U+FFFD substitution per Unicode §3.9 (matches Rust `String::from_utf8_lossy`).  Total; never raises. |
| `"concatBytes"` on `List` | `List[ByteArray] -> ByteArray` | Concatenate elements in order.  Empty list → zero-length `ByteArray`.  Non-`List` or non-`ByteArray` element raises `MethodNotDefined` (matches existing convention). |

These are stateless, deterministic method additions to the interpreter method table.  All three are additive — they introduce new method names and never reprice an existing operation — so they don't invalidate history.  They still need coordinated activation behind a version gate.

### 2. Library agents (Rholang; genesis-installed)

Standard-library agents authored as `agent` blocks and published to the versioned registry via blessed genesis deploys.  All state lives in the tuplespace under `*this`-keyed private channels.

| Agent | URN | Purpose |
|---|---|---|
| `Buffer` | (private inside allocator) | Fixed-size byte buffer.  §Buffers. |
| `Rows` | (private inside allocator) | Buffer of buffers.  §Fixed-size line reading. |
| Allocator | `rho:lang:buffer:1.0.0` | Mints `Buffer` and `Rows` instances. |
| `Stream` (base) | (private inside `File` / other producers) | Base stream methods. |
| `CharStream` / `ByteStream` / `EntryStream` / `LineStream` | (private) | Specializations. |
| `File` | (private inside `Fs`) | Open file descriptor wrapper.  §File. |
| `Dir` | (private inside `Fs`) | Directory root wrapper.  §Dir. |
| `Fs` | `rho:io:fs:1.0.0` | Top-level; `openFile`, `openDir`, `stdin`, `stdout`, `stderr`. |
| `Stdin` / `Stdout` | (private inside `Fs`) | Process stdio wrappers. |

The genesis deploy installs all seven (allocator + `Fs`) plus their internal agent classes in a single scope-closed `new` block, so the native URNs are bound only inside that scope and the class channels are only reachable through the published bundles.

### 3. Powerbox + static provisioning (Rust + Rholang config)

- CLI flags (`--oracle-static-file`, `--oracle-static-dir`, `--consensus-static-*`) and config-file entries materialize into a boot-time `(logicalName, canonPath, mode)` bundle.
- Boot-time validation walks each provisioned tree, rejects `is_symlink()` and (Unix) `nlink() > 1`.
- The bundle is handed to a genesis-installed powerbox contract that hands per-principal `Fs` instances to callers (per the powerbox FIP; interim stub is a single `Fs` shared until that FIP lands).

## Phased plan

Each phase leaves the tree buildable and testable.  Phases 1-2 are pure Rust additions; 3-7 are Rholang libraries + genesis wiring; 8-10 are integration and polish.

### Phase 0 — Prerequisites (verify only)

Confirm on `f1r3node-rust` main:

- `agent`, `private`, `!?`, `try`/`catch` sugars all compile.
- `u64` / `u8` numeric-type literals parse and evaluate.
- Versioned Registry lookup (`new x(`urn:1.0.0`) in { ... }`) resolves to genesis-installed agents.
- `NonNegativeNumber.rho` / `Stack.rho` still ship as the canonical agent-block precedents.
- `toUtf8Bytes` is in the reduce.rs method table (the inverse decoders don't exist yet).

If any of these are missing, stop and coordinate with the prerequisite-FIP owner.

### Phase 1 — Native filesystem primitives

**Scope**: 22 filesystem syscalls — 21 as originally scoped (`open`, `close`, `read`, `readAt`, `write`, `writeAt`, `seek`, `tell`, `size`, `truncate`, `flush`, `stat`, `exists`, `entries`, `rename`, `copyFile`, `removeFile`, `removeDir`, `chmod`, `chown`, `quarantine`) plus `entriesStream` (see below).

**Deliverables**:

- `rholang/src/rust/interpreter/io/` module tree:
  - `handle_table.rs` — `Arc<RwLock<HashMap<u64, FileHandle>>>`, `snapshot_next_fd` + `truncate_to`.
  - `path.rs` — `canonicalize_and_quarantine(root, rel) -> Result<PathBuf, QuarantineError>`.  Rejects empty, `.`-only, `..`-escape, symlink traversal, root-self.
  - `mode.rs` — parse the eight fopen modes; parse the 9-char rwx mode string to `u16` bits.
  - `stat.rs` — build the entry record `{name, kind, size, mode, mtime, ctime, atime, owner, group}` in the two consensus/oracular shapes.
  - `nss.rs` — `resolve_uid`/`resolve_gid` via `getpwnam_r`/`getgrnam_r`; distinguish not-found (`None`) from transient failure (`Err`).
  - `response.rs` — `[true, ...]` / `[false, code, msg]` helpers.
- **Mode-enum threading**: introduce a `ConsensusMode` enum with variants `Oracular` and `Consensus`, thread it from `ProcessContext` (constructor-time) → `SystemProcesses` → every path-taking native handler.  `stat.rs::stat_record` branches on the enum to omit `mtime`/`ctime`/`atime`/`owner`/`group` in `Consensus` mode; `chown` handler short-circuits with `"FSERR_UNSUPPORTED"` in `Consensus`.  Include a Rust-side unit test that runs the same `stat` call under both modes and diffs the record shape.
- **Native `entriesStream(canonPath) -> [true, streamFd]`**: streaming entry-listing primitive.  Uses `tokio::fs::read_dir` under the hood, yielding one record per pull.  Backing state lives in a handle table analogous to `FileHandleTable` — same lifecycle discipline.  This is what `Dir.entries()` in Phase 5 wraps into an `EntryStream` agent; without it, `Dir.entries()` would have to materialize the whole listing (defeating the point of §Efficiency for large files).  Alternative discussed and rejected: keep only bulk `entries` and layer streaming atop it at the agent level — that would still materialize once inside the native, so it wouldn't help memory bounds.
- `FixedChannels` + `BodyRefs` entries for each URN.  All 22 in `non_deterministic_ops()`.
- URN filter in `rho_runtime::is_internal_urn` (`starts_with("rho:io:fs:native:")`).  **Slice 19 removed this filter uniformly so genesis could bind fs-native URNs; slice 31 (planned) restores it as a phase-scoped `NormalizerEnv` construction — genesis path includes the fs-native URNs, state path omits them (PB-B-1 resolution, Q-1 2026-07-30).**
- Per-call caps: `MAX_READ_BYTES = 64 MiB`, `MAX_TRUNCATE_BYTES = 16 GiB`.
- Fd-table lifecycle: snapshot/truncate wired into the deploy path (production, not just `evaluate_with_env_and_phlo`).  `FSERR_QUOTA_EXCEEDED` emit site for per-runtime + per-deploy fd caps.

**Design constraints** (from spec):

- Every path-taking native takes `(rootCanon, rel)` and quarantines internally.
- `entries` uses `symlink_metadata` uniformly with `stat`/`exists`; a per-entry error becomes a row with an error field rather than aborting the listing.
- `chmod`/`chown` use `AT_SYMLINK_NOFOLLOW` (`fchmodat` / `lchown`).
- `open` rejects non-regular files with `"FSERR_UNSUPPORTED"`.
- Consensus mode: `chown` returns `"FSERR_UNSUPPORTED"`; `stat`/`entries` omit `mtime`/`ctime`/`atime`/`owner`/`group`.

**Tests**:

- Unit tests per native (positive + FS-error + BAD_ARG + quarantine-escape + oversized).
- Integration tests: `rholang/tests/fileio_native_spec.rs` — deploy an inline `.rho` calling each native by fixed channel, verify replies.
- Replay tests: `rholang/tests/fileio_replay_spec.rs` — play, mutate disk, replay, assert reply matches captured log.
- Fd-lifecycle tests: `rholang/tests/fileio_lifecycle_spec.rs` — deploy that opens+errors, verify fd table rolled back on the *production* deploy path.

**Effort**: 4–5 days.

### Phase 2 — UTF-8 helpers and `concatBytes`

**Scope**: three additions to `reduce.rs`'s method table.

**Deliverables**:

- `validUtf8PrefixLen` on `ByteArray` — total; charged proportional to byte length.
- `decodeUtf8` on `ByteArray` — total (U+FFFD substitution); charged proportional to byte length.
- `concatBytes` on `List` — total on `List[ByteArray]`; raises `MethodNotDefined` off-domain.  Charged linearly in total byte length.
- Cost entries in `accounting/costs.rs` mirroring `hex_to_bytes_cost`.
- `rho_type.rs` reuse of `RhoByteArray` / `RhoString` (no new type).

**Design constraints**:

- All three total on their documented domains — must never raise an uncatchable `InterpreterError` for any well-typed input.
- Additive protocol change — no repricing.
- Coordinated activation behind the version gate that ships the buffer library.

**Tests**:

- Unit tests: valid UTF-8, ill-formed UTF-8, edge cases (empty, U+FFFF, multi-byte splits).
- `concatBytes`: single-element list, empty list, multi-element list, non-`List` receiver, non-`ByteArray` element.

**Effort**: 1–2 days.

### Phase 3 — Buffer library + allocator

**Scope**: `Buffer.rho` and `Rows.rho` library agents, allocator publishing.

**Deliverables**:

- `casper/src/main/resources/Buffer.rho` — the buffer library, containing:
  - The `Buffer` agent class: `writeByte`, `writeBytes`, `read`, `slice`, `toByteArray`, `validUtf8PrefixLen`, `view`, `capacity`, `length`, `remaining`, `isEmpty`, `isFull`, `unit`, `beginFill`, `endFill`, `clear`, `close`, `default`.
  - The `Rows` agent class: `capacityRows`, `innerUnit`, `getAt`, `clear`, `close`, `default`.
  - The allocator (factory): `alloc(nUnits, unit)`, `allocBytes(n)`, `allocUtf8(n)`, `allocRows(m, innerN, innerUnit)`, `default`.
  - The module-level `merge` contract for pairwise chunk gather (§Cost accounting > Buffers).
- Metadata token: `@(*this, *metaP)!((ℓ, ρ, C, unit, lease, lo, hi))` or `"REVOKED"`.  Free-variable `match` in every method with the three-arm structure (tombstone / live tuple / defensive fall-through).
- Chunk storage: `@(*this, *chunkP, j)!(segment)`; **monotonic indices are a permanent invariant** — `clear` advances `lo` to `hi`, never resets to zero; a chunk index is *never* reused across the buffer's lifetime.  This invariant is load-bearing for consensus safety: any future optimization tempted to reset `lo = 0` on empty would break replay for historical blocks that referenced higher indices.  Mandate it in code as a `// NEVER REWIND lo — consensus-safety invariant, see FIP §Buffers` comment on the `clear` implementation.
- `writeByte` byte→ByteArray via a 16-entry hex-digit map + `hexToBytes` (no new interpreter primitive).
- Type guards on every numeric / `ByteArray` argument with `match`, before any arithmetic; capacity checks ordered `n ≤ n_max(unit)` before `n * 4` (to avoid uncatchable overflow).
- `StandardDeploys` entry: blessed keypair, timestamp, deploy function.
- Genesis wiring: register `rho:lang:buffer:1.0.0` in the Versioned Registry at genesis.

**Design constraints** (from §Buffers):

- Every named method acquires the metadata token first; chunk-touching reads verify `lease == none` under the same token.
- `clear`/`close` await every chunk removal before re-parking the metadata token, on every exit path.
- `chunk` uses linear-receive + explicit-re-send (not peek), for self-contained safety.
- Chunk gather is a balanced pairwise merge using `concatBytes` — never `++` or an accumulating fold.

**Tests**:

- Unit tests via `.rho` scripts run through the runtime:
  - Basic: `alloc(64, "bytes")` → `writeBytes` → `read` → verify content.
  - Reuse: multi-round `clear` → `writeBytes` → `read`, verify no accumulation.
  - Boundary: full-buffer write short-writes; `writeByte` on full → `"BUFERR_CAPACITY_EXCEEDED"`.
  - Encoding: `view()` on valid UTF-8; on mid-code-point-truncated → `"BUFERR_BAD_ENCODING"`.
  - Revocation: `close` → subsequent named methods → `"BUFERR_REVOKED"`; `default` → `"BUFERR_UNSUPPORTED"`.
  - Lease: `beginFill` then chunk-touching read → `"BUFERR_FILLING"`; `endFill` with wrong token → `"BUFERR_FILLING"`.
  - `allocRows`: verify inner-buffer count, `getAt` bounds, cascaded `clear`.
  - Type guards: `writeByte(-1)` / `writeByte(256)` → `"BUFERR_INVALID_ARGUMENT"`.
- Cost tests — pairwise-merge growth: run `read` on a buffer that was filled with `ν = 8`, `ν = 64`, and `ν = 512` chunks; assert cost follows `Θ(ℓ log ν)`, not `Θ(ℓ ν)`.  A `ν = 1` test cannot catch a fold-vs-merge regression (nothing to merge), so this is the actual guard — a future refactor to `List.fold(concatBytes)` would silently quadruple cost between `ν = 64` and `ν = 512` and this test would catch it.
- **Monotonic-index regression test**: allocate → write → `clear` → write → capture the chunk index of the new write; assert it is strictly greater than the largest index used before the `clear`.  Repeat across 100 iterations to catch any future accidental `lo = 0` reset.

**Effort**: 7–10 days (the library is the most intricate Rholang code in the FIP: three-arm `match` with defensive fall-through on ~20 methods, monotonic chunk-index discipline, pairwise merge in Rholang, fill lease that survives abandonment, capacity-check ordering to avoid uncatchable overflow, U+FFFD-avoiding `view()`, Rows agent with cascaded clear/close awaits, plus StandardDeploys wiring, blessed keypair, and Versioned Registry publication — the mutex + lease + monotonic-indices discipline needs careful review, and this is the first agent-library authored under the new spec).

### Phase 4 — Stream library

**Scope**: `Stream.rho` (base) + `CharStream.rho` / `ByteStream.rho` / `EntryStream.rho` / `LineStream.rho` (specializations).

**Deliverables**:

- Base `Stream` agent class with `next`, `chunk`, `close`, `fold`, `foldChunks`, `forEach`, `foldConcurrent`, `mapReduce`, `default`.
- Specializations: each is an `agent` block that inherits the base surface and specializes the `chunk` container type (`String` / `ByteArray` / `List` / not-supported for `LineStream`) and materialization helpers (`toString(cap)` / `toByteArray(cap)` / `toList(cap)`).
- `LineStream` single-active-inner rule: outer's `next` closes any active inner before returning the next; drained inners fail closed with `"FSERR_CLOSED"`.
- EOS convention: `[false, "EOS", msg]` returned by `next`/`chunk`; caught internally by `fold`/`foldChunks`/`forEach`/`foldConcurrent`/`mapReduce`.
- Concurrency parameter validation: `workers` and `chunkSize` positive `u64`; zero → `"FSERR_BAD_ARG"`; over-cap → `"FSERR_QUOTA_EXCEEDED"`.
- Replay-determinism: parallel combinators' scheduling captured in the produce log via the existing non-deterministic-replay mechanism.
- Genesis publishing (if needed as a standalone URN) or private-to-Fs (if only reachable through producers).  Recommend: private-to-Fs for MVP; expose separately later if a stream-consumer FIP demands it.

**Design constraints**:

- Streams are `bundle+{*this}` (never expose raw dispatch channel).
- `Nil` is a legal stream value; EOS is the distinct `"EOS"` error-shape.
- Source cursor coupling: one active sequential stream per underlying source; positional streams coexist per range-lock rules.
- Combinators auto-close their stream on return (success / EOS / error).

**Tests**:

- Base methods: `next` → value → EOS → verify caller pattern; `chunk` with `n = 1`, small, capped.
- Combinators: `fold` counts bytes; `foldChunks` counts via chunks; `forEach` echoes to stdout; `foldConcurrent` with 8 workers verifies commutative-combine convergence; `mapReduce` sum-of-squares.
- **LineStream negative-path matrix (four tests)**: `LineStream.chunk(n)`, `LineStream.foldChunks(...)`, `LineStream.foldConcurrent(...)`, and `LineStream.mapReduce(...)` all return `[false, "FSERR_UNSUPPORTED", ...]` — the single-active-inner rule makes each impossible.  Each is a distinct spec obligation and needs its own test.
- LineStream lifecycle: outer `next` drains previous inner; retained-inner post-drain observes `"FSERR_CLOSED"` on `next`, `chunk` (returns `FSERR_UNSUPPORTED` first — good), *and* `fold` (which must not silently succeed with an empty accumulator; it must propagate the `FSERR_CLOSED`).
- EOS handling: `fold` on empty stream → success reply with `init`; error propagation on combine failure.
- **Stdin `wait: true` policy** (spec ambiguity — decide and test): `stdin!lines({"wait": true})` should be either accepted (blocks until stdin has data) or rejected with `"FSERR_BAD_ARG"` (stdin has no acquire-cursor semantics).  Recommend: accept and treat as a no-op on a source that doesn't multiplex; document in the `Stdin` section.

**Effort**: 4–5 days.

### Phase 5 — File + Dir agent library

**Scope**: `File.rho`, `Dir.rho` — the read/write/stream/buffer surface on open handles.

**Deliverables**:

- `File.rho` agent class:
  - Read-side stream producers: `chars`, `bytes`, `lines`, `linesAsStrings(perLineCap)`, `forEachLine(handler, perLineCap)`, `readLine`, `bytesAt(offset, length)`.  Sequential producers accept `{"wait": true}`.
  - Write-side stream consumers: `writeChars`, `writeBytes`, `writeLine`, `writeLines`, `writeString(s)`, `writeByteArray(bytes)`, `writeBytesAt(offset, maxLength, byteStream)`.
  - Buffer-taking methods: `readInto(buf)`, `readAtInto(offset, buf)`, `readLineInto(buf)`, `readLinesInto(rows)`, `writeFrom(buf)`, `writeFromAt(offset, buf)`.  Each acquires the buffer's fill lease with `beginFill`, drives sequential `@buf!writeBytes(chunk)` awaits, releases with `endFill` on every exit path.
  - Cursor + size: `seek`, `tell`, `size`, `truncate`.
  - Durability: `flush`.
  - Lifecycle: `close` (force-closes active streams via `bundle+`-held stream handles).
  - Permissions: `chmod(mode)`, `chown(owner, group)`.
  - Explicit range lock: `lockRange(offset, length, mode)` → `LockToken` agent with `release()`.
- `Dir.rho` agent class:
  - Listing: `entries()` → `EntryStream`.
  - Metadata: `stat(rel)`, `exists(rel)`.
  - Composition: `openFile(rel, options)`, `openDir(rel, options)`.  Both mode-attenuate monotonically.
  - Mutation: `removeFile(rel)`, `removeDir(rel, options)`, `rename(from, to)`, `copyFile(from, to)`, `chmod(rel, mode)`, `chown(rel, owner, group)`.  All mutation methods return `"FSERR_UNSUPPORTED"` on a `"r"` Dir.
- Mode-string parser (Rholang): parse `"rwxr-xr-x"` to `u16` bits; symbolic-delta forms (`"u+x"`) and octal strings (`"0755"`) → `"BUFERR_BAD_ARG"`.
- Argument-shape checks per §Argument conventions: methods with Bool/List/tagged-option args do a one-line `match` before dispatch.

**Design constraints**:

- Every path-taking `Dir` method quarantines its argument first (via the native `quarantine` primitive).
- `File.openFile` (via `Dir`) verifies file-kind via `stat` before opening; `Dir.openDir` does the same (already in the spec).
- Buffer-taking read methods READ THE BUFFER'S `unit()` and apply the UTF-8 boundary rule for `"utf8"`-unit buffers.
- Concurrency partition: sequential vs. positional per §Concurrency and locking; single active sequential stream per File; range locks on positional.

**Partial dependency on Phase 8**: `File.readLine` returns a pre-exhausted `CharStream` on EOF (spec §File.readLine); the pre-exhausted behavior is trivial, but the sequential-cursor-conflict / `{"wait": true}` semantics that `readLine` sits under only become fully live once Phase 8 lands range locks + sequential-stream wait.  Phase 5 delivers the method with a placeholder concurrency behavior ("second sequential call returns `FSERR_BUSY` immediately, no wait"); Phase 8 augments to add `{"wait": true}` blocking.  A short section in Phase 8's deliverables covers the augmentation.

**Tests**:

- Per-method integration tests via `.rho` scripts, including a **default-arm matrix**: send an unknown method (`file!wibble()`, `dir!wibble()`) to each of File, Dir → each replies `[false, "FSERR_UNSUPPORTED", ...]`.
- Stream+File composition: `file!chars()` → consume via `toString(cap)`; `file!lines()` → outer/inner drain sequence.
- Buffer+File composition: allocate a buffer, `file!readInto(buf)`, verify content; large-file bounded-memory test (§Efficiency for large files).
- Dir composition: `dir!openFile(rel, {"mode": "r"})` on a `"rw"` Dir; verify `"r"`-mode attenuation of the returned File.
- Concurrency (Phase 5 slice — before Phase 8 lands `wait`): two sequential streams → second gets `"FSERR_BUSY"`; positional-vs-sequential conflict.  Phase 8 tests add `{"wait": true}` blocking behavior.
- Force-close: `File.close` while a stream is held elsewhere; verify stream sees `"FSERR_CLOSED"` on next call.

**Effort**: 8–11 days (~30 methods on `File` + ~10 on `Dir`, each with quarantine, attenuation, argument-shape checks, and error-code coverage; plus the mode-string parser in Rholang; plus the File-buffer integration lease discipline on every fill path).

### Phase 6 — `Fs` agent, stdio, genesis wiring

**Scope**: `Fs.rho` top-level entry point, `Stdin.rho` / `Stdout.rho`, genesis deploy.

**Deliverables**:

- `Fs.rho` agent class:
  - Methods: `openFile(name, options)`, `openDir(name, options)`, `stdin()`, `stdout()`, `stderr()`.
  - Options handling: mode capped at statically-provisioned mode; downgrade succeeds; upgrade → `"FSERR_UNSUPPORTED"`.
  - ~~Cached agent instances per `(canonicalPath, resolvedMode)` on the *same* `Fs` instance.~~  **Reverted (slice 27).**  Cache violates POSIX-like per-open cursor semantics: two `openFile(same-name, same-mode)` calls must yield distinct `File` agents with independent read/write positions, otherwise Alice's `read` advances Bob's cursor and vice versa.  Shared *contents* remain coordinated by Phase 8 range locks, not by cap-sharing.  Cache dropped; every `openFile` / `openDir` mints fresh (mirrors slice 18's stdio fix, same rationale).
- `Stdin.rho`: `chars`, `bytes`, `lines`, `readLine`, `close`; positional methods `"FSERR_UNSUPPORTED"`.
- `Stdout.rho`: `writeChars`, `writeBytes`, `writeLine`, `writeLines`, `writeString`, `writeByteArray`, `flush`, `close`; read methods `"FSERR_UNSUPPORTED"`.
- Genesis deploy source (`FsGenesis.rho` or similar) that composes all library classes in a single `new` scope binding the native URNs via `NormalizerEnv` injections, then publishes `Fs` at `rho:io:fs:1.0.0`.
- `StandardDeploys` entry for the genesis deploy.
- `Registry.rho` signed shorthand entry for `rho:io:fs:1.0.0`.  **Revised 2026-07-30 (PB-B-3 resolution):** the FsGenesis deploy publishes at `rho:id:<hash>` derived from `FS_GENERATOR_PK` via `insertSigned`; a subsequent `insertVersion` call registers `rho:io:fs:1.0.0` (and `rho:io:fs:1.*` wildcard) as a normalization-time alias for that `rho:id:<hash>`.  URNs in `new x(`urn`)` are static literals resolved at deploy-time normalization — the versioned registry is a normalization-time table, not a runtime lookup service.  Dynamic URN construction / runtime URN lookup is a future FIP, out of scope here.  Scheduled: **Phase 7 slice 25** (bundle handoff to genesis) or a dedicated genesis-registry slice.  No longer a Powerbox blocker.
- Legacy `rho:io:stdout` / `rho:io:stderr` shim contracts marked deprecated (removal target `rho:io:fs:2.*`).  Slice 20 delivered this via code-comment + spec docstring only — no runtime signal, per Phase 6 whole-phase review (spec's "deprecation-notify channel" language applies only to Versioned Registry URNs, which legacy flat URNs are not).

**Design constraints**:

- The `Fs` agent's `openFile`/`openDir` fail with `"FSERR_UNSUPPORTED"` if the logical name isn't in the static bundle.
- ~~Cache **does not cross `Fs` boundaries** — each principal gets a fresh `Fs` from the powerbox.~~  **Obsolete (slice 27):** cache dropped entirely.  `Fs` is stateless w.r.t. handed-out handles; a shared `Fs` cap is safe because every `openFile`/`openDir` mints a fresh, independent `File`/`Dir` agent.  This also collapses powerbox-doc Q-2 (cache-scoping question) into a non-issue.
- Stdio replay: lead-node stdin reads captured; followers replay from the log.  **Deferred to Phase 10** — the capture/replay path around `Stdin`'s `fsRead` handler wasn't wired in Phase 6.  Belongs with the E2E replay harness (`fileio_replay_spec.rs`) once the ocap examples are landing.
- Stdio in cases 4-6: default `/dev/null`-equivalent; powerbox overrides.  **Deferred to the Powerbox slice** (see PB-M-2) — Phase 6 hardwires (0, 1, 2) at `Fs!?(0, 1, 2, ...)` mint time.

**Tests**:

- Full-stack: static-config → `Fs` genesis → user deploy calls `fs!openFile("config/theme.json", {"mode": "r"})` → `file!chars()` → `chars!toString(64000)`.  **Delivered** (partial) via `casper/tests/genesis/contracts/fs_generator_spec.rs`: runs `fs_generator("root")` through the RhoSpec harness, verifies URI resolution + `openFile` empty-bundle FSERR_UNSUPPORTED + `stdout()` return shape.  Full `file!chars() → chars!toString(64000)` round-trip is deferred until Phase 7's static provisioning wires an actual `config/theme.json` bundle entry — then the Phase-10 examples exercise it end-to-end.
- Stdio: `fs!stdout()!writeString("hi")` prints; `fs!stdin()!lines()` echo loop.  **Delivered** via `fs_stdout_write_string_succeeds` + `fs_stdio_echo_lines_end_to_end` in `rholang/tests/file_dir_check.rs`.
- ~~Cache: repeated `openFile(same-name, same-mode)` returns the same handle; repeated with different mode → distinct handle (or attenuated).~~  **Reverted (slice 27):** repeated `openFile(same-name, same-mode)` must return DISTINCT handles with independent cursors (POSIX open-twice semantics).  Same-name-same-mode-returns-same-handle would silently share Alice and Bob's read position.  Slice 27 replaces this test with `openFile_twice_yields_distinct_handles_with_independent_cursors` — asserts two calls produce structurally distinct `File` agents and that a `readN(k)` on one does not advance the other's position.  Attenuation (deriving a lower-mode cap from a higher-mode one) becomes an ocap-forwarder pattern, not an Fs-side cache concern.
- **Default-arm matrix** on `Fs`, `Stdin`, `Stdout`: unknown method → `[false, "FSERR_UNSUPPORTED", ...]`.  **Delivered** — `stdin_positional_methods_return_fserr_unsupported`, `stdout_read_methods_return_fserr_unsupported`, `fs_unknown_method_after_slice_18_still_unsupported`.
- **Cross-`Fs` ocap-isolation test** (a first-class MVP test, not "once powerbox stub exists"): use the genesis machinery to construct two `Fs` instances directly with distinct `deployerId`s from the stub Powerbox; call `openFile("shared/logical/name")` on each; assert the returned `File` handles are structurally distinct agents backed by distinct fds, and that a membrane wrapped around Alice's `File` is invisible to Bob when Bob opens by the same logical name.  **Delivered** (essence) via `cross_fs_alice_manipulation_invisible_to_bob` — Alice's close on her cap has no effect on Bob's independently-obtained cap; the Rholang membrane forwarder itself is deferred (Rholang syntax requires more scaffolding than a regression test warrants; close-probe demonstrates the same isolation invariant).  Full membrane-wrapped ocap test lands with the Powerbox slice + Phase-10 `fileio_membrane.rho` example.
- Replay: end-to-end example runs on the leader, its non-deterministic events captured; a follower replay produces the same `ProcessedDeploy` tree.  **Deferred to Phase 10** — see above stdio-replay deferral.
- **Consensus-mode replay**: run the same `stat`-and-`entries` example on the leader against a `consensus-static-*` path; capture the record shape (with host-transient fields omitted); replay on a follower and assert the reply is *byte-identical*.  Lives in `fileio_consensus_replay_spec.rs` (see §Test infrastructure).  **Deferred to Phase 7** — `ConsensusMode` is enum-threaded from Phase 1 but never SET to `Consensus` (Fs.rho has no mode-per-cap wiring; runtime hardcodes `Oracular`).  Setting it requires **per-cap** plumbing driven by config-bucket routing (`oracle-static-*` vs `consensus-static-*`) — Q-7 resolution 2026-07-30: mode is per-file/dir, not per-principal, so the cap itself carries the mode from mint time.  Phase 7 slice 26's territory.

**Powerbox stub deliverable** (see plan §494 / plan-tail powerbox note): the interim per-`deployerId` stub Powerbox listed as an in-Phase-6 deliverable was **not built**; Phase 6 shipped the shared-Fs MVP instead.  See `powerbox-requirements.md` PB-M-1 for the tracking entry and design questions Q-1..Q-8 for the delegation-mechanism trade-offs.  The stub is a dedicated future slice, blocking on: (a) `NormalizerEnv` plumbing decision (Option A / B / C in `powerbox-requirements.md` §5), (b) Phase 7's config → bundle handoff.

**Effort**: 4–5 days delivered as slices 14-20 (Stdin, Stdout, Fs.openFile/openDir, ~~Fs.cache~~, Fs.stdio, FsGenesis, legacy-shim doc).  Powerbox stub not counted in this budget; slotted as a distinct future slice.

**Slice 27 (Phase 6 retrofit)**: revert slice 17's Fs cache.  **Delivered 2026-08-04; review fixes landed same day.**  **Review fixes (2026-08-04):** H-27-2 `openFileImpl` (and `openDirImpl` as mirror) validate `cmode` BEFORE calling `fsOpen`/`fsStat` — a bad cmode now returns `FSERR_BAD_ARG` without allocating a kernel fd, closing the fd-leak vector where the M-26-2 constructor-side REVOKED path would leave a fd registered in `FileHandleTable` that `File.close` never dispatches `fsClose` for.  Refactor: the pre-fix bodies moved to `openFileImplInner` / `openDirImplInner`; the outer contracts do only the cmode match+delegate.  ST-27-4 `standard_deploys_spec::fs_generator_composed_source_contains_expected_shape` extended with negative assertions that the composed source does NOT contain `fsCacheP`, `cacheAndOpenFile`, `cacheAndOpenDir` — a regression re-adding the cache is now caught by an integration test.  **Documented deferrals (from review — Cost FIP / slice 31 territory):** H-27-1 & H-27-F1 (per-runtime fd cap DoS aggravated by fresh-mint, no per-deploy sub-cap); M-27-F1 (mint-path `fsStat` runs on every fresh open — Consensus operators must freeze `consensus-static-*` paths for the entire deploy lifetime, not just first cache-populating call); M-27-F2 (deploy-cost blowup: legacy code paying O(1) for repeat opens now pays O(N)); M-27-1 & I-27-F3 (handle equality is now consensus-observable and always false for repeat opens — release-notes item); L-27-1 (tuplespace state cells grow per-mint); H-27-3 (native URN filter — slice 31).  M-27-2 / L-27-F1 (`fileCtor` naming fragility): deferred as minor; explicit comment can land alongside slice 26's ConsensusMode threading review pass.  **Review-fix tests added (2026-08-04):** 5 Rust unit tests in `handle_table.rs`: `open_same_file_twice_yields_distinct_fds_with_independent_cursors` (MT-27-1 — the *core* POSIX invariant, unprovable at the Rholang-mock layer because the mock uses one shared cursor cell), `close_one_fd_does_not_affect_the_other`, `insert_at_cap_returns_err_and_recovers_on_remove` (MT-27-2 — `MAX_OPEN_FDS` enforcement), `next_fd_is_monotonic_across_remove` (regression pin: fds never rewind), `truncate_to_snapshot_leaves_pre_snapshot_intact`.  5 Rholang integration tests in `file_dir_check.rs`: `open_file_impl_rejects_bad_cmode_before_calling_fs_open` (H-27-2 regression), `fs_open_file_repeated_same_key_yields_pairwise_distinct_handles` (ST-27-1 — three opens, all pairs asserted distinct via `==`-false), `fs_open_file_three_distinct_opens_are_pairwise_distinct` (ST-27-2), `fs_open_file_close_twice_on_same_cap_stable` (ST-27-3 — restored per-cap idempotent-close coverage after slice-17 test was deleted).  Concurrent-open par test (MT-27-3) deferred — the invariant is safe by construction (`fsBundleP` non-linear peek `<<-` is race-free per Rholang semantics) and sequential fresh-mint distinctness already exercises the identical code path; deferred as NT-27-4.  **Green results:** rholang lib 5/5 new handle_table tests + rholang file_dir_check 421/421 (up from 417) + casper standard_deploys_spec 9/9 (with new negative assertions) + casper lib 281/281.  Fmt + clippy clean.  **Pre-fix delivery notes preserved below.**  Per POSIX-like semantics clarified 2026-07-30: every `openFile`/`openDir` mints a fresh agent with its own cursor; shared byte-level state is coordinated by Phase 8 range locks, not by cap-memoization.  Removed the `fsCacheP` cell and the module-level `cacheAndOpenFile` / `cacheAndOpenDir` contracts from `Fs.rho`; `openFile` / `openDir` methods now invoke `openFileImpl` / `openDirImpl` directly (defined in `Dir.rho`).  Composed source's outer `new` clause in `fs_genesis.rs::compose_fs_genesis_source` and the `with_libs` test helper both dropped the removed names.  `Fs.rho` docstring rewritten: the "Cache (slice 17)" section replaced with a "Fresh-mint semantics (slice 27)" section that documents the POSIX-open-twice invariant and its Phase-8-range-lock rationale.  **Test changes:** deleted 6 tests that asserted cache HIT (SAME handle returned for repeat opens: `fs_open_file_cache_same_key_returns_same_handle`, `fs_open_dir_cache_same_key_returns_same_handle`, `fs_open_file_cache_same_key_handles_are_structurally_equal`, `fs_open_dir_cache_same_key_handles_are_structurally_equal`, `fs_open_file_cache_key_uses_resolved_mode_r`, `fs_open_file_cache_closed_handle_repeated_close_stable`); rewrote 9 tests to drop cache-specific language (kept assertions still valid: distinct-mode / distinct-name / cross-Fs / reply-shape / three-concurrent — all still hold under fresh-mint); deleted slice-26's `fs_open_file_consensus_cache_keyed_on_cmode` and `fs_open_file_consensus_cache_hits_on_same_key` (moot with cache gone).  **New tests:** `fs_open_file_twice_yields_distinct_handles_with_independent_state` (open twice; close first; second remains open — proves independent per-agent `stateP`); `fs_open_dir_twice_yields_distinct_handles`; `fs_open_file_after_close_yields_fresh_handle` (three opens, each after a close, all succeed); `fs_open_file_consensus_twice_yields_distinct_handles` (mirror of the two-opens invariant for consensus caps); `fs_open_file_oracle_and_consensus_caps_over_shared_path_are_independent` (renamed replacement for the cache-keyed test, still asserts distinct routing to distinct native arms).  **Green results:** rholang file_dir_check 417/417 (down from 420 net — 3 cache-HIT tests deleted, replacements added); casper lib 281/281 including 41/41 fs_genesis; casper contracts integration 34/34.  **Note:** the spec doesn't currently reference handle memoization in §867 (or elsewhere in the FIP); no spec backport needed.

**Closed-state semantics audit (2026-07-30, no new slice — verified as part of slice 22 review):** with tokenized cost accounting, deploys no longer have run-to-completion semantics; File/Dir agents follow scope, not deploy boundaries.  It is valid for a File agent to reference a closed file.  Verified already implemented in `File.rho`: constructor initializes state to `"open"`; `close` transitions to `"closed"` on every path (including error and state-unrecognized branches); every method reads state, matches on `"closed"`, and short-circuits to `[false, "FSERR_CLOSED", ...]`; unknown state also falls through to `"closed"`; `default(...@args)` returns `FSERR_UNSUPPORTED` (independent of state).  `Dir.rho` holds only path metadata (no fd), so no closed state is needed — a Dir handle is inherently durable across restarts and errors on the underlying filesystem operation if the directory is gone.  Streams (CharStream, ByteStream, LineStream, EntryStream, Rows) call back into their parent File and inherit `FSERR_CLOSED` naturally.  The remaining runtime-side work is PB-M-13 (startup re-close pass on `RhoRuntimeImpl` boot); scheduled as a Phase 7 or post-Phase-7 deliverable alongside the WAL/snapshot infrastructure.

### Phase 7 — Static provisioning (config + CLI + boot validation)

**Scope**: the `node` binary's config loader and CLI flag parser for the static-provisioning surface.

**Deliverables**:

- Config-file schema for `storage { oracle-static-files, oracle-static-dirs, consensus-static-files, consensus-static-dirs }`.  Keys are logical paths (multi-segment, `/`-separated); values are either a `{path, mode}` map or a bare string.
- CLI flags: `--oracle-static-file`, `--oracle-static-dir`, `--consensus-static-file`, `--consensus-static-dir`.  Repeatable.  Same schema as the config.
- Boot-time validation:
  - Every configured path is absolute.  Reject relative.
  - Every path is UTF-8.
  - O(tree) walk rejects `is_symlink()` and (Unix) `nlink() > 1` on regular files.  Fail-to-launch on any violation.
  - `"wx"` / `"w+x"` rejected in config (they require non-existence, contradicting the config's existence check).
  - Duplicate detection: same path in config + flag → error; same logical key with different definitions → error.
  - Absolute-prefix symlink diagnostic (macOS `/tmp` → `/private/tmp`): tell the operator to supply the canonical path.
- Default modes: `"rw"` for `--*-static-dir`, `"r"` for `*-static-dirs` in config.
- Bundle passed to genesis: `Vec<(logicalName: String, canonPath: PathBuf, kind: File|Dir, mode: String, consensusMode: ConsensusMode)>`.  **Bundle-shape revision 2026-07-30 (Q-7 resolution):** added `consensusMode` field.  Mode is per-**file/dir**, not per-principal — the bucket the path came from (`oracle-static-*` vs `consensus-static-*`) is the mode.  The tuple carries it forward so the Fs.rho constructor and downstream File/Dir agents can dispatch on it at native-call time.
- **`ConsensusMode` per-cap plumbing** ~~(moved from Phase 6 per whole-phase review B-P6-5)~~ **Revised 2026-07-30 (Q-7 resolution):** `ConsensusMode` is a *per-File/Dir-cap* value, not per-principal / per-deploy.  Origin: the config bucket a path came from.  Propagation: bundle tuple → `Fs!?(...)` constructor → each File/Dir constructor → native handler dispatch site.  `handlers.rs::fs_chown` reads the cap's mode (not deploy context) and short-circuits to `FSERR_UNSUPPORTED` in Consensus; `stat_record` reads it and omits host-transient fields.  Streams inherit the source File's mode.  Phase 1 threaded the enum from `ProcessContext`; Phase 6 defaulted every principal to `Oracular`; Phase 7 provides the actual per-cap setter driven by the bundle tuple's `consensusMode` field.
- **Startup re-close pass** (PB-M-13, added 2026-07-30 per Q-6 resolution): on `RhoRuntimeImpl` boot, walk the tuplespace and rewrite every File-agent state `"open"` → `"closed"`.  Rationale: with tokenized cost accounting, File agents outlive their originating deploy; on node restart the per-runtime fd table is gone but the agent state survives, so agents must be transitioned to the `"closed"` sentinel that `File.rho` already handles.  Applies to both oracle and consensus modes; deterministic (all validators do the same rewrite at boot).
- **Consensus-mode filesystem WAL** (PB-M-14, added 2026-07-30 per Q-6 resolution): every mutating operation on a `consensus-static-*` path (`write`, `writeAt`, `truncate`, `chmod`, `chown`, `remove*`, `rename`, `copy*`) is journaled to the block as a WAL entry BEFORE being applied to the underlying store.  A joining node replays the WAL against a base image (from PB-M-15's latest snapshot) to reconstruct current filesystem contents.  Determinism requirement: WAL entries carry only the operation kind + resolved-path + payload; host-transient fields (uid/gid on `chown`, timestamps) are omitted or normalized (identical to `stat_record`'s field-omission rule).  **Hash-only payload (2026-08-03):** WAL entries carry a cryptographic hash of bytes read/written, NOT the bytes themselves — except for bytes already on-chain as deploy data, which are referenced directly by block position.  Bounds on-block WAL size to `O(hash_len × ops)` regardless of write volume; a separate protocol (Phase 7b) distributes byte payloads to joining nodes who validate against WAL hashes.  Reads that consume file bytes record the resulting hash so replay is byte-identical.  `oracle-static-*` paths do NOT journal — oracle-mode writes are per-validator-local and never part of consensus state.
- **Consensus-mode periodic snapshots** (PB-M-15, added 2026-07-30 per Q-6 resolution): periodic snapshots of the consensus filesystem prevent unbounded WAL replay for late-joining nodes.  Snapshot cadence is a configurable node parameter (config key `storage.consensus-fs-snapshot-cadence`); **no default per 2026-08-03 decision — operator must set the value; missing value fails boot with a clear diagnostic pointing operators at the tradeoff (snapshot cost vs late-join replay length).**  Snapshot on-disk area is `storage.consensus-fs-snapshot-dir`.  Snapshot contents are content-addressed (deterministic hash) so all validators emit identical snapshot roots at the same block height.  Joining node fetches the snapshot at the last-checkpointed block, then replays WAL entries from that block forward.  Retention is a **separate required config key** (`storage.consensus-fs-snapshot-retain`, 2026-08-11 promotion of F-30b-1 disposition from optional-with-`cadence * 2`-heuristic to explicit-required): operator declares how many snapshots to retain; missing value fails boot with a diagnostic pointing at the tradeoff (disk footprint vs late-join replay window).  Slice 35's operator-tunable override (delivered) is the implementation substrate; the schema change is to remove the `Option<usize>` default and require the field alongside cadence when any `consensus-static-*` is provisioned.
- **Phase 7b — byte-payload distribution protocol** (scoped 2026-08-11, decomposition after design review).  The Phase 7 WAL is hash-only; joining validators can verify hashes but need the actual bytes to reconstruct filesystem state.  Approach follows Option C from the 2026-08-11 review (snapshot-embedded bulk + on-demand between-snapshot fetch):
  - **Phase 7b-1 — Snapshot chunk-fetch.**  Chunk each snapshot into fixed-size pieces (proposed 4 MiB per chunk); build a Merkle tree over per-chunk Blake2b256 hashes; snapshot root = Merkle root (which PB-M-15 already commits to on-chain).  Extend Casper's existing block-fetch machinery with a companion `get_snapshot_chunk(snapshot_root, chunk_index)` opcode; reuses peer discovery, connection management, DoS defenses, and peer-scoring from block fetch.  Joiner fetches chunks with per-chunk hash verification and assembles the snapshot locally.  Any node that has the chunk serves it; validators are authoritative sources but non-validator archive nodes can serve too.
  - **Phase 7b-2 — Between-snapshot on-demand byte fetch.**  For WAL entries between the joiner's latest snapshot and the head block, the joiner enumerates the payload hashes referenced by the WAL and asks peers for bytes by hash via a companion `get_wal_payload(payload_hash)` opcode.  Same fetch/verify/store shape as chunk-fetch; each response validates against the requested hash before being applied to the local filesystem.  Between-snapshot demand is bounded by `cadence × avg_write_size` so this doesn't grow unboundedly.
  - **Write-payload determinism as demand-reducer, not eliminator.**  The plan §372 "bytes already on-chain as deploy data are referenced directly by block position" observation generalizes: consensus-write bytes SHOULD trace to on-chain sources (deploy data + deterministic Rholang + operator-provisioned static content) whenever possible.  When they do, the joiner replays deploys and produces the bytes locally — no `get_wal_payload` request needed.  This dramatically reduces Phase 7b-2 demand without requiring a hard invariant that every write's bytes be reproducible.  Writes whose bytes originate outside the reproducibility chain (e.g., operator-added consensus content) fall back to `get_wal_payload`.
  - **Availability + retention.**  Retention for WAL payload bytes matches snapshot retention (bytes needed to reconstruct any block between the earliest retained snapshot and head).  Nodes MAY prune older payload bytes once they've been superseded by a snapshot the node accepts.  Archive nodes retain everything and are the fallback for cross-snapshot historical fetches.
  - **Rejected alternatives** (per 2026-08-11 review):
    - Push bytes during block gossip — defeats hash-only WAL's whole purpose (bytes still travel with every block).
    - Full DHT-style content-addressed store (BitTorrent/Kademlia) — new P2P layer separate from Casper block gossip; overkill for this shape.
    - Strict write-payload determinism invariant that eliminates all cross-node byte transport — too restrictive for the operator-added-static-content case; adopted as *demand-reducer* only.

**Design constraints**:

- Every validation error batches into a single `Vec<FileIoConfigError>` (or equivalent) so the operator sees all violations in one boot error.
- Consensus-static entries provisioned but only exercised under the deferred consensus-mode FIP.
- Mode routing (`oracle-static-*` vs `consensus-static-*`) determines the `ConsensusMode` value threaded into each **cap's** handler dispatch — see PB-M-12 in powerbox-requirements.md.  Per-file/dir, not per-principal.
- **Bucket disjointness (PB-M-16, added 2026-07-30):** boot validation must reject any path appearing in both `oracle-static-*` and `consensus-static-*`, plus any prefix overlap between the two bucket sets (e.g., `oracle-static-dir "/foo"` + `consensus-static-file "/foo/bar"`).  A single filesystem entity cannot be both consensus-replicated and oracle-local.  Batched into the boot error report.

**Tests**:

- Config parse: valid, malformed, mode-string errors, non-absolute-path errors, `"wx"` in config, duplicate keys.
- Boot validation: temp trees with symlinks / hard-links / non-UTF-8 names.
- CLI-config equivalence: same content via flag vs. config produces the same bundle.
- **Startup re-close pass (PB-M-13):** open a File agent, kill the runtime mid-deploy, restart, verify the File's next method returns `[false, "FSERR_CLOSED", ...]` and the fd is not stale-read.
- **Consensus-mode WAL (PB-M-14):** mutate a consensus file on validator A; bring validator B online from genesis + WAL only; assert byte-identical file contents.  Assert that mutations on `oracle-static-*` paths produce zero WAL entries.
- **Consensus-mode snapshot (PB-M-15):** with cadence set to N=5 blocks, verify a joining node at block 20 fetches the block-15 snapshot and replays 5 WAL entries.  Assert content-addressed snapshot root is byte-identical across all validators at any given block height.

**Slice status**:

- Slice 21 — HOCON schema + validators.  **Delivered** in `node/src/rust/configuration/file_io_provisioning.rs`: `StaticFileEntry`/`StaticDirEntry`, `serde(untagged)` value shapes, `CONFIG_FILE_MODES`/`CONFIG_DIR_MODES` whitelists, `validate_absolute_path`, `check_provisioning_typos`, `validate_size_limits` + 32 tests.
- Slice 22 — CLI-flag parsers.  **Delivered** in `node/src/rust/configuration/commandline/cli_static_provisioning.rs` (19 parser tests) + four `Vec<CliStatic{File,Dir}Arg>` fields on `RunOptions` in `options.rs` (6 clap integration tests via `Options::try_parse_from`).  CLI dir default is `"rw"` (spec §1252); file default is `"r"`.  Parsers exposed via `ValueParser::new(parse_cli_static_file)` / `parse_cli_static_dir`, `ArgAction::Append` for repetition.  Merge with config-file entries + duplicate detection = slice 24; bundle handoff to genesis = slice 25.
- Slice 23 — Boot-time tree walk validators.  **Delivered 2026-08-03** in `node/src/rust/configuration/boot_validation.rs`.  Public entry point `validate_provisioning_boot(&FileIoProvisioning) -> Result<(), Vec<FileIoConfigError>>`.  Error variants: `IsSymlink`, `AbsolutePrefixSymlink`, `HardLinked`, `PathNotFound`, `StatFailed`, `BucketOverlapSamePath`, `BucketOverlapPrefix`, `KindMismatch`.  All errors batched into a single `Vec` (plan §370 constraint).  18 tests including symlink-as-entry, symlink-descendant, hard-linked file, ancestor-symlink diagnostic, bucket disjointness (same-path + prefix overlap in both directions), same-bucket overlap allowed, string-prefix-only doesn't overlap, kind mismatch both directions, multi-error batching, Display coverage.  Slice 24 will merge CLI entries into the validator's input.
- Slice 24 — Merge + duplicate detection + batched errors.  **Delivered 2026-08-03** in `node/src/rust/configuration/provisioning_merge.rs`; **review-driven fixes landed same day.**  Public entry points: `merge_cli_into_config(...) -> (FileIoProvisioning, Vec<FileIoConfigError>)` (merge-only, errors sorted) and `merge_and_validate(...) -> Result<FileIoProvisioning, Vec<FileIoConfigError>>` (boot-integration surface, errors from both stages combined and sorted).  Three new `FileIoConfigError` variants: `DuplicateLogicalNameAcrossSources` (**hard reject per M-24-2 option c**: config entry REMOVED from merged map, CLI not inserted, boot fails on any error — no silent precedence), `DuplicateLogicalNameInCli` (first-wins intra-source), `DuplicatePathAcrossSources` (uses lexical normalization so `/etc/foo` and `/etc/./foo` compare equal, checks ALL CLI entries including those dropped by hard-reject).  Identical duplicates silently deduped.  Pre-merge size cap (`MAX_PROVISIONING_ENTRIES`) short-circuits to bound cost against hostile inputs.  Path-dedup is O(N+M) via HashMap indexed on normalized paths.  **42 tests**, all pass; full node lib 291/291 green.  Slice 25 will call `merge_and_validate` from the boot pipeline; must also synthesize `(kind, consensusMode)` per plan §369 (documented as TODO in module preamble).
- Slice 25 — Bundle handoff to genesis.  **Delivered 2026-08-03; review fixes landed 2026-07-29.**  New types in `casper/src/rust/genesis/contracts/fs_genesis.rs`: `pub struct BundleEntry { logical_name, canon_path, kind, mode }` and `pub enum BundleEntryKind { File, Dir }`.  New function `format_bundle_for_rholang(&[BundleEntry]) -> String` produces the Rholang map literal for the `Fs!?(0, 1, 2, <bundle>)` position; entries sorted by logical name for byte-identical composed source across validators (consensus requirement).  `compose_fs_genesis_source` and `fs_generator` gained a `bundle: &[BundleEntry]` parameter; `Genesis` struct gained `fs_bundle: Vec<BundleEntry>`; `default_blessed_terms` / `create_genesis_block` thread it through.  Node-side: `provisioning_merge::project_bundle(&FileIoProvisioning) -> Vec<BundleEntry>` walks the merged four buckets and synthesizes `BundleEntryKind` from map type.  Rholang string escaping (backslash, quote, newline, tab — **NOT `\r`**, which the Rholang lexer rejects) applied defensively despite slice-21/22 rejecting NUL and control chars.  All existing genesis callers updated to pass empty bundle (preserves pre-slice-25 behavior); `BlockApproverProtocol` gained a matching `fs_bundle` field/parameter so validator-side genesis composition is byte-identical to the proposer's; node's boot pipeline populates from `merge_and_validate` at `CasperLaunchImpl::new` construction.  **Deferred to a follow-up slice:** ~~PB-B-3 `insertVersion` call for `rho:io:fs:1.0.0` / `rho:io:fs:1.*` (versioned-registry mechanics separate concern)~~ **RESOLVED 2026-08-24 — insertVersion wired under `rho:serve:1.0.0:<hex>:fs:1.0.0`**; FIP-canonical `rho:io:*` bare-alias shape still pending a URN-parser extension slice and the `consensusMode` 5th tuple field (slice 26 will add both to the tuple and thread through Fs.rho / File.rho / native dispatch).  **Review fixes (2026-07-29):** C-25-2 `rholang_string_escape` now panics on any C0/C1 control char instead of emitting `\r` (the composed source would fail genesis with a lexer error on legitimate Windows-CRLF operator input); H-25-1 manual `Hash` impl on `Genesis` sorts `fs_bundle` by `logical_name` before hashing so reordered bundles hash identically (matches the sort-then-emit invariant in `format_bundle_for_rholang` — required for `DashMap` semantics + downstream consensus keys); H-25-2 hex validation on `pk_hex`/`sig_hex` promoted from `debug_assert!` to `assert!` for release builds; H-25-3 `BundleEntry::try_new` fallible constructor validates UTF-8, absolute-path, and forbidden-chars invariants as defense-in-depth against programmatic bypass (slice 24's `project_bundle` now uses it exclusively, panicking on projection-path failure); H-25-4 `format_bundle_for_rholang` panics on non-UTF-8 `canon_path` rather than emitting U+FFFD (which would silently open a different file at runtime); M-25-6 dedup assertion in `format_bundle_for_rholang` (would otherwise silently overwrite in the Rholang map); M-25-7 boot validation gained `LogicalNameConflictAcrossOracleConsensus` variant + cross-source name-conflict check (Fs.rho's `bMap` is a single namespace, so same key across oracle+consensus buckets would silently collapse); node-side `file_io_provisioning::reject_forbidden_chars` extended to reject NUL, C0/C1 controls, DEL, BOM, RTL overrides (U+200E/F, U+202A-E, U+2066-9), and line separators (U+2028/9) at HOCON deserialization, with the mirror set duplicated in `fs_genesis::reject_char_set` (casper cannot depend on node).  **Tests:** 4 `project_bundle` tests + boot-validation cross-source-conflict tests (node), 6 `format_bundle_for_rholang` tests + 15 review-driven regression tests (dedup panic, non-hex pk/sig panic, control-char escape panic, 10 `BundleEntry::try_new` validation cases, 2 composed-source-compiles-through-Rholang-parser cases) + 2 `Genesis::hash` order-insensitivity tests (casper), all 9 existing `standard_deploys_spec` genesis-integration tests still pass.  Full node lib 295/295; casper lib 274/274; genesis integration 9/9.
- Slice 26 — `ConsensusMode` **per-cap** setter plumbing.  **Delivered 2026-08-03; review fixes landed 2026-08-04.**  **Review fixes (2026-08-04):** C-26-F1 `resolve_cmode` fails **closed** — any non-`"oracular"`/`"consensus"` Par returns `None` and the handler surfaces `FSERR_BAD_ARG` instead of silently defaulting to Oracular (which would have been a network-fork tripwire: two validators seeing different bad-parse Par shapes would produce divergent stat/entries records).  H-26-F1 `stat_record` under Consensus now masks mode to `& 0o0777` (perm bits only), dropping setuid/setgid/sticky which can vary across validator hosts (umask, install(1), overlayfs) — Oracular keeps the full 12 bits for host-level ergonomics.  H-26-F3 `ConsensusMode::default()` flipped from `Oracular` to `Consensus` — the more restrictive mode — so any future refactor that lands a handler consulting `self.mode` fails closed by default.  M-26-1 stale docstrings in Fs.rho updated to describe the 5-tuple bundle shape and the (canonRoot, rel, mode, kind, cmode) cache key.  M-26-2 File and Dir constructors validate `cmode` at mint time — a bogus string / Nil / non-String value REVOKES the agent's state (stateP = "closed", rootP = "REVOKED") so every subsequent method surfaces `FSERR_CLOSED` or `FSERR_IO` instead of silently accepting attacker-chosen mode.  M-26-3 the `"oracular"` / `"consensus"` string constants moved to `rholang/interpreter/io/mod.rs` (`CMODE_ORACULAR_STR` / `CMODE_CONSENSUS_STR`) and `BundleConsensusMode` re-exports them — single source of truth; a drift-assertion test pins the pair.  L-26-F1 `meta_time_ms` uses `i64::try_from(as_millis()).unwrap_or(i64::MAX)` (saturating conversion) instead of `as i64` wrapping.  L-26-F2 fs_chown validates cmode BEFORE the Consensus short-circuit so a garbled cmode never silently reaches the fallback.  **Deferrals from review (not fixed):** H-26-F2 (mutable-file `size` under Consensus) is an operator-invariant issue — the `consensus-static-*` bucket documentation warns to use only frozen paths; a future slice may add mint-time content-hash verification.  H-26-F4 (URN filter removed, MVP #5) is the scheduled slice-31 deliverable.  M-26-F1 (signature scope) is a documentation-only note.  M-26-F3 (NSS PII leakage under Oracular) is an operator-hygiene concern.  M-26-F4 (project_bundle HashMap iteration) is defense-in-depth: the two subsequent sorts already provide determinism, and a slice-26 review-fix test (`compose_fs_genesis_source_is_deterministic_across_runs`) pins the invariant.  H-26-3 (cross-bucket same canon_path) is already covered by slice 23's `check_bucket_disjointness` → `BucketOverlapSamePath`.  **Review-fix tests added (2026-08-04):** 15 `resolve_cmode` unit tests in `handlers.rs` (accepts each valid string; rejects capitalized, whitespace-padded, empty, Int, Bool, ByteArray, Nil, BoundVar, unknown strings; pins `ConsensusMode::default() = Consensus`; asserts CMODE_*_STR constants); 4 `stat_record` unit tests in `stat.rs` (consensus strips setuid/setgid/sticky; oracular preserves them; consensus omits mtime/ctime/atime/owner/group; oracular includes mtime); 2 casper `Genesis` hash tests (`genesis_hash_differs_when_only_cmode_differs`; `bundle_entry_ne_when_only_cmode_differs`); 2 casper composed-source tests (mixed-mode assertion that both strings appear at the 5th tuple position; `compose_fs_genesis_source_is_deterministic_across_runs`); 2 node `project_bundle` tests (same-name-across-oracle-consensus produces both entries; empty-bucket variant); 9 Rholang integration tests (File.chown consensus r-mode / rw-mode denies; Dir.chown consensus r-mode; **nested openDir cmode inheritance** — parent Consensus → child Consensus with chown short-circuit; consensus + bad owner reports BAD_ARG; consensus + Nil/Nil short-circuits; File/Dir constructor validation for bogus cmode; cache-HIT symmetry on same-key openFile).  **Deferred (2026-08-03 delivery notes preserved below).**  New enum `BundleConsensusMode { Oracular, Consensus }` in `casper/src/rust/genesis/contracts/fs_genesis.rs` with `as_str()` / `parse_str()` bracketing the Rholang string boundary (`"oracular"` / `"consensus"`).  `BundleEntry` gained a `consensus_mode: BundleConsensusMode` field; `BundleEntry::try_new` accepts the mode as a required argument.  `format_bundle_for_rholang` now emits 5-tuples `(canonRoot, rel, mode, kind, cmode)` — one extra element after `kind`.  Node-side `provisioning_merge::project_bundle` derives cmode from the source bucket: `oracle-static-*` → `Oracular`, `consensus-static-*` → `Consensus`.  **Rholang side (Fs.rho):** the `bMap.get(n)` match pattern is now 5-arity; `cacheAndOpenFile` / `cacheAndOpenDir` gained a `cmode` param and thread it through to `openFileImpl` / `openDirImpl`; the cache key is 5-tuple `(canonRoot, rel, mode, kind, cmode)` so two logical names pointing at the same physical path but with different modes get SEPARATE cache slots (an oracular cap cannot borrow a consensus cap's slot).  **Dir.rho:** `openFileImpl` / `openDirImpl` take a `cmode` param, pass it to `Dir!(..., cmode, fileCtor)` (child Dir inherits parent's mode) and `@fileCtor!(..., mode, cmode)`; `stat` / `entries` / `chown` methods peek a new `*cmodeP` state cell (persistent non-linear `<<-`, set once at ctor) and forward the string to `fsStat` / `fsEntries` / `fsChown`; internal `openFile` / `openDir` methods also peek and pass the cmode.  **File.rho:** constructor gained a 5th param `@cmode`; a new `*cmodeP` cell holds it alongside `*fdP` and `*stateP` — kept separate rather than appended to the 4-tuple `fdP` state so we don't have to update the ~24 pattern-match sites in File.rho (only `chown`, the sole currently-implemented method that differs by consensus mode, peeks the new cell).  **Rust native handlers (rholang/src/rust/interpreter/io/handlers.rs):** `fs_stat` / `fs_entries` / `fs_chown` signatures now take a `cmode` string arg; a new `resolve_cmode(par, default)` helper parses `"oracular"` / `"consensus"` and falls back to the runtime-wide `self.mode` (still Oracular by default) on unknown / non-String values — so any caller that hasn't been updated preserves legacy behavior.  On a Consensus cap `fs_chown` short-circuits with `FSERR_UNSUPPORTED` without touching the filesystem.  **Tests:** 3 new casper lib tests (`consensus_mode_as_str_round_trips`, `format_bundle_emits_consensus_mode_as_5th_tuple_element`, mixed + consensus-only composed-source parse) + 1 project_bundle assertion extension; 3 new Rholang integration tests (`fs_open_file_consensus_mode_per_cap_chown_routing` — two caps in one deploy route to distinct arms; `fs_open_file_consensus_cache_keyed_on_cmode` — cache slot isolation; `fs_open_dir_consensus_mode_chown_short_circuits` — Dir.chown mirrors File.chown).  Full node lib 295/295; casper lib 277/277; casper integration (fs_generator_spec + standard_deploys_spec + genesis_test + block_approver_protocol_test) 23/23; rholang file_dir_check 411/411.  **Deferred to future slices:** `stat` / `entries` field-omission on Consensus caps is native-side (handlers.rs already reads `mode` via `resolve_cmode`), but reachability requires a genesis-integration test that actually mints a Consensus cap and calls `stat`; the current suite tests `chown` short-circuit and cache-key isolation, and slice 29 (consensus-mode WAL) will add the stat/entries field-omission integration coverage as part of the replay test infrastructure.
- Slice 28 — Startup fd-watermark PB-M-13.  **Delivered 2026-08-04; review fixes landed same day.**  **Review-refuted findings:** C-28-F1 ("LFS-joining validators fork on their first fs_open") and C-28-F2 ("long-lived vs. restarted validator divergence") assumed a runtime accumulates `next_fd` across blocks — but `RuntimeManager::spawn_runtime` at `casper/src/rust/util/rholang/runtime_manager.rs:263` creates a fresh runtime per compute call, so every block starts from `next_fd=1` before the seed applies.  Both long-running and LFS-joining validators go through identical per-block-fresh paths.  Documented in the reviewer's own security agent output as safe by architecture.  **Review fixes applied (2026-08-04):** H-28-F1 raised entropy from 4 bytes (~65k-block birthday collision) to 8 bytes with 20-bit per-lifetime headroom mask (~4M-block birthday collision, ~130 years at 1 block/sec).  New constant `FD_ENTROPY_HEADROOM_BITS = 20` with a `const _: () = assert!(MAX_OPEN_FDS * 2 < 1 << FD_ENTROPY_HEADROOM_BITS)` compile-time invariant guard (ST-28-4).  H-28-F2 hardened `FileHandleTable::insert` with a wrap guard: pre-fetch check that rejects at `u64::MAX` + post-increment defensive check + counter roll-back on wrap — translated to `FSERR_QUOTA_EXCEEDED` upstream.  L-28-F1 added `debug_assert!(hash.len() >= 8)` in `seed_next_fd_from_state_hash`.  M-28-2 revised the `reset()` docstring to accurately describe the statistical-not-guaranteed cross-block aliasing prevention.  M-28-F2 documented the fd derivation as an explicit consensus commitment (hard-fork implication of any change).  M-28-F1 documented the reset side-effect in the docstring with an inventory of call sites and the "fresh runtime per compute call" containment argument.  **Review-fix tests (2026-08-04) — 9 total:** 4 new unit tests in `handle_table.rs` (`seed_from_state_hash_reserves_low_bits_for_headroom` pins the mask; `insert_returns_err_when_next_fd_at_u64_max` proves wrap-guard behavior; `allocations_within_headroom_budget_stay_in_bucket` verifies 100 alloc+close cycles stay within the same watermark bucket; `seed_from_short_hash_debug_asserts` catches the L-28-F1 regression via `#[should_panic]`).  4 new integration tests in `rholang/tests/fs_next_fd_seed_spec.rs` (`reset_seeds_fs_handles_from_state_hash` MT-28-1 — the ONLY test proving the wiring in `RhoRuntimeImpl::reset`; `two_runtimes_at_same_hash_have_identical_next_fd` MT-28-2 — determinism across runtime instances; `genesis_empty_state_hash_seeds_expected_next_fd` ST-28-5 — golden-value pin for the empty-state hash so a change to `RadixHistory::empty_root_node_hash` trips a test; `reset_does_not_perturb_urn_filter_state` — cross-slice-28/31 invariant).  **Deferrals from review (2026-08-04):** H-28-F3 (play/replay runtimes have separate `fs_handles`) — low-likelihood and requires a bigger refactor; H-28-1 (mid-block reset ordering fragility) — consensus-safe today by construction; L-28-1 (32 bits of state-hash prefix exposed via fd values) — fd values are already public via tuplespace state, no confidentiality issue; NT-28-1..6 (concurrent stress, Rholang-observable fd assertion, three-lifetime chain, etc.) — nice-to-have.  **Green results (post-fixes):** rholang io::handle_table 15/15 (up from 11), rholang fs_next_fd_seed_spec 4/4, rholang fs_native_urn_filter_spec 9/9, rholang file_dir_check 421/421, casper lib 281/281, casper genesis integration 34/34.  Fmt + clippy clean.  Prevents post-restart fd aliasing: pre-restart, Deploy A opens a File with fd=42 and stashes the cap in tuplespace; node restarts; fresh `FileHandleTable::next_fd` starts at 1; Deploy B's 42nd open would allocate fd=42; Deploy A's stashed cap invoked later via `fsRead(42, ...)` would silently read from Deploy B's file.  **Design pivot from the original plan-authors' "rewrite stateP cells at boot" approach:** rewriting Rholang state cells requires either (a) modifying File.rho's state layout with a Rust-scannable marker and touching ~24 pattern-match sites, or (b) publishing `stateP` GPrivate name via a well-known URN and scanning the tuplespace at boot for entries at channels containing that name.  Both approaches are heavy; both are consensus-sensitive.  The alternative that achieves the same safety property with far less surface: seed `FileHandleTable::next_fd` deterministically from the state hash at every `reset()` so post-restart allocations never overlap with any pre-restart fd value.  Stale `stateP` cells still show `"open"` after a restart, but the subsequent `fdP` dereference goes to a fresh fd table where the value is absent → the native handler returns `FSERR_CLOSED` (existing behavior).  Aliasing is prevented at the fd-allocation layer, not by rewriting Rholang state.  **Implementation:** `FileHandleTable` gained two methods — `seed_next_fd_watermark(u64)` (monotonic; CAS loop; multiple calls with the same or smaller value are no-ops) and `seed_next_fd_from_state_hash(&[u8])` (takes first 4 bytes of the hash as u32, left-shifts 32 to place watermark in upper half of u64 — a single runtime lifetime bounded by `MAX_OPEN_FDS = 1024` cannot overflow into the next watermark's range).  `RhoRuntimeImpl::reset` calls `seed_next_fd_from_state_hash(&root.bytes())` after `space.reset()` so every block boundary re-seeds.  Determinism: same state hash → same watermark on every validator; captured leader fd values replay identically on followers.  **Tests:** 5 new in `handle_table.rs`: watermark-raises-next_fd, watermark-monotonic-no-op-on-smaller, seed-deterministic-across-runtimes, seed-differs-for-different-prefixes, post-restart-fd-allocation-does-not-alias-stale-fds (aliasing regression), different-state-hashes-produce-disjoint-fd-ranges (cross-block isolation).  **Green results:** rholang handle_table 11/11 (5 new + 6 preserved), rholang file_dir_check 421/421, rholang fs_native_urn_filter 9/9, casper lib 281/281, casper genesis integration 34/34.  Fmt + clippy clean.  **Deferred:** the plan's original stateP-rewrite variant remains available if a future review shows the fd-watermark approach has gaps (e.g., if fd values ever get consumed by non-fd purposes in tuplespace state, though no such use is expected).
- Slice 31 — Phase-scoped URN visibility PB-B-1.  **Delivered 2026-08-04; genesis-replay gap fix 2026-08-05.**  **Genesis-replay gap (2026-08-05, discovered during slice 29 round-2 verification):** the original slice 31 delivery only toggled the URN filter around `play_deploys_for_genesis` (leader side) but not `replay_deploys` (follower / block-approver / validate-checkpoint side).  Replaying a genesis block re-executes the FsGenesis ProcessedDeploy which binds `rho:io:fs:native:*` URNs — with the filter left on during replay, every genesis validation failed with `ReplayStatusMismatch { initial_failed: false, replay_failed: true }`.  Fix mirrors the play-side pattern: `replay_deploys` in `replay_runtime.rs` gates on `!with_cost_accounting` (the caller's genesis signal, see line 113) and disables the filter around the user-deploy loop with a try/finally-style wrapper so the filter re-enables even on error.  Fixes 2 previously-failing casper mod tests: `block_approver_protocol_should_successfully_validate_correct_candidate`, `validate_block_checkpoint_recompute_rejects_pre_state_and_rejected_deploy_tampering`.  A third failure (`compute_block_checkpoint_should_merge_histories_in_case_of_multiple_parents_uneven_histories`) has an unrelated root cause — a documented merge-algebra order-dependence (`docs/theory/merge-algebra/merge-algebra-verification.md §6 Finding A`) — and is outside slice 29 / slice 31 scope.

  (Original slice 31 delivery notes preserved below.)  Closes MVP simplification #5 / H-26-F4 / H-27-3 documented as "MUST FIX BEFORE PRODUCTION" since slice 19.  Instead of building two separate `urn_map`s per deploy path (originally proposed), the filter is implemented as a single `Arc<AtomicBool>` on the reducer (`DebruijnInterpreter::filter_fs_native_urns`) that gates `eval_new`'s URN lookup by a prefix check (`FS_NATIVE_URN_PREFIX = "rho:io:fs:native:"` in `rholang/interpreter/io/mod.rs`).  ON by default (state-execution deploys reject fs-native URN bindings with `ReduceError` referencing the URN); toggled OFF around `play_deploys_for_genesis` in `casper::rholang::runtime` via new `RhoRuntimeImpl::disable_fs_native_urn_filter` / `enable_fs_native_urn_filter` methods, with a try/finally-style wrapper so the filter is re-enabled even on error.  Prefix-based check covers every current and future suffix (Phase 8's `lockRange`/`releaseLock` URNs would be automatically included if they land under the same prefix).  Fs.rho's composed source (bound in the genesis path) can still bind `fsRead`/`fsWrite`/etc.; user deploys can only reach the filesystem through the `Fs` cap published at genesis via `insertSigned`.  **Docstring updates:** `fs_genesis.rs` MVP #5 section rewritten to mark the item RESOLVED with a pointer to slice 31; the two related comments in `rho_runtime.rs` (`std_system_processes` fs-native section and `setup_maps_and_refs` insert loop) also updated.  **Tests:** 9 in `rholang/tests/fs_native_urn_filter_spec.rs`: filter is ON by default, toggle methods flip and are idempotent, state deploy binding any fs-native URN fails with `ReduceError` (all 20 URN suffixes iterated), non-fs URNs pass through unaffected, genesis-scope binding (filter OFF) resolves cleanly, re-enabling the filter after a genesis batch restores protection, prefix-based check catches unknown fs-native URNs (future-suffix defense-in-depth), rejection is `ReduceError` (not `BugFoundError`).  Pre-existing `fs_generator_spec.rs` end-to-end test (RhoSpec-harness openFile via the published Fs cap) already exercises the FULL path — filter ON during the state-executed user deploy that looks up the cap and invokes openFile.  **Green results:** rholang fs_native_urn_filter_spec 9/9, casper genesis integration 34/34 including fs_generator_spec 1/1, casper lib 281/281, rholang file_dir_check 421/421.  Fmt + clippy clean.
- Slice 29 — Consensus-mode WAL PB-M-14 **MVP delivered 2026-08-04; correctness redesign delivered 2026-08-05; round-2 review fixes delivered 2026-08-05.**

**Round-2 review fixes (2026-08-05):** post-redesign review found the C-29-F1 fix was *itself* broken (C-R1: `fs_open`'s `is_replay` short-circuit skipped fd-table insertion → follower's `journal_write` no-op'd on unknown fd → same leader/follower WAL divergence the fix was supposed to close) plus a still-open native-layer defense-in-depth gap (C-R2) and a latent nested-checkpoint bug (H4/M1).  Fixes landed:
- **C-R1** (`handle_table.rs`, `handlers.rs`, `response.rs`): `FileHandle::file` is now `Option<File>`.  New `FileHandleTable::insert_at(fd, handle)` inserts at a specific fd without advancing the allocator.  `fs_open`'s `is_replay = true` branch extracts the leader's fd from `previous` via new `extract_ok_u64` helper and inserts a *shadow handle* (`file: None`, populated cmode + canon_path).  Follower's subsequent `journal_write` / `journal_truncate` now find `(cmode, canon_path)` and append identically to the leader.  `raw_fd()` returns `None` for shadow handles — read/write paths short-circuit on `is_replay = true` before reaching the OS fd, so `None` is never dereferenced.  Regression pin: `fs_wal_spec::wal_is_byte_identical_on_leader_and_follower` — the definitive leader/follower symmetry test using ReplayRSpace machinery.  Also `handle_table::insert_at_places_shadow_handle_at_specified_fd` and `insert_at_occupied_slot_returns_false`.
- **C-R2** (`handlers.rs`, `Dir.rho`, `File.rho`): `fs_chmod`, `fs_remove_file`, `fs_remove_dir`, `fs_rename`, `fs_copy_file` now take a `cmode` arg and fail-closed with `FSERR_UNSUPPORTED` on Consensus at the native layer, mirroring slice-26's `fs_chown` pattern.  Defense-in-depth beneath the round-1 Rholang H-29-3 guards: genesis-scope code that URN-binds these natives directly (URN filter is off during genesis) now hits the native gate.  Rholang callers pass `cmode` from their state.  Test mocks in `file_dir_check.rs` updated to the new arity and to mirror the native fail-closed behavior.  Regression pins: 5 new `native_fs_*_consensus_returns_unsupported` tests + 3 new H7/H8/H9 pins (`file_chmod_consensus_r_mode_returns_unsupported` proves the consensus guard fires before the mode gate and preserves distinctive message text; `dir_remove_file_consensus_does_not_invoke_syscall` and `file_chmod_consensus_does_not_invoke_syscall` prove no syscall dispatch when the Rholang guard fires).
- **H4/M1 nested checkpoint bug** (`rho_runtime.rs`): `wal_snapshot` and `fs_snapshot` are now `Vec<...>` stacks instead of single-slot `Option<...>`.  `create_soft_checkpoint` pushes; `revert_to_soft_checkpoint` pops.  Pre-fix, nested `create` calls silently overwrote the outer mark → revert-to-outer only unwound to the inner boundary.  Regression pin: `fs_wal_spec::nested_soft_checkpoints_preserve_outer_wal_mark`.
- **M-R3** (`handlers.rs`): `MAX_WRITE_BYTES` check moved BEFORE `journal_write` in `fs_write` and `fs_write_at`, mirroring `fs_truncate`'s correct pre-check ordering.  Pre-fix, an oversized write consumed a WAL slot for a call that would then error out (deterministic but wasteful, and adversarially exploitable for cheap DoS on the WAL cap).
- **M-R2** (`path.rs`): new `canonicalize_lexical(root, rel)` helper that removes `.` components and collapses duplicate `/` separators so equivalent rel forms (`a/b.txt`, `./a/b.txt`, `a//b.txt`) produce byte-identical `PathBuf`s in WAL entries.  Applied at both the leader's `open_impl` and the follower's shadow-handle construction so both sides see the same canon_path regardless of caller-side rel canonicalization.  4 unit tests in `path::path_tests`.
- **M6 (reset also clears checkpoint stacks)** (`rho_runtime.rs::reset`): `reset()` now clears `fs_snapshot_stack` and `wal_snapshot_stack` alongside `wal.clear()`.  Pre-fix, resetting after a create-without-revert left a stale mark that a subsequent revert would pop and act on.

**Deferred to slice 30 (documented in plan and code):**
- **H-R2** (hard checkpoint WAL snapshot): no `revert_to_hard_checkpoint` exists today, but if slice 30 introduces one it must snapshot/restore the WAL alongside the fd table.  Documented as a slice-30 constraint rather than eager infrastructure.
- **H-R3** (Par-parallel WAL ordering non-determinism): the wal.rs header comment's determinism claim assumes single-scheduler ordering, but Rholang `Par` under tokio spawn is scheduler-dependent.  Slice 30's on-chain WAL commitment design will decide whether to serialize Consensus writes via a runtime-wide semaphore, reject concurrent Consensus writes, or accept the ordering as scheduler-observable.
- **H-R4 / M-29-3** (partial-write divergence): still recording REQUESTED bytes; deferred as documented in round-1 notes.
- **M-R1** (block-wide WAL cap DoS): per-deploy cost accounting for WAL slots is a Cost FIP concern.
- **M-R4** (fs_open `is_replay` skips cmode validation): inherent to the is_replay pattern; not a bug today (leader's validation is cached in `previous`) but noted as a footgun for future hard forks.

**Round-2 test coverage delta:** wal handle_table unit 27/27 (added `insert_at_places_shadow_handle_at_specified_fd`, `insert_at_occupied_slot_returns_false`).  fs_wal_spec 14/14 (was 11; added `wal_is_byte_identical_on_leader_and_follower`, `wal_cap_returns_fserr_quota_exceeded_from_rholang`, `nested_soft_checkpoints_preserve_outer_wal_mark`).  file_dir_check 435/435 (was 427; added 3 H7/H8/H9 pins + 5 C-R2 native gate pins).  path::path_tests 4/4 (new).

**Redesign summary (2026-08-05):** the security / FIPS / test-coverage review of the original MVP surfaced two Critical bugs plus several highs.  Fixes were bundled as a single-slice redesign rather than a follow-up because they overlap the WAL append site, the is_replay short-circuit, and the checkpoint machinery.
- **C-29-1** (`handlers.rs::open_impl`): `FileHandle::canon_path` is now `PathBuf::from(&root).join(&rel)` instead of the pre-fix `.join("")` no-op that dropped `rel` — every WAL entry had recorded only the canonRoot with no way to distinguish files under the same root at replay time.  Regression pin: `fs_wal_spec::wal_entries_include_rel_in_path`.
- **C-29-F1** (`handlers.rs::fs_write` / `fs_write_at` / `fs_truncate`): the WAL append now runs BEFORE the `is_replay` short-circuit on both leader and follower, from data fully derivable from contract args (path via fd lookup, `Blake2b256` hash of REQUESTED bytes, requested length + offset).  Pre-fix, only the leader appended — the follower took the `previous`-cached reply and never entered `write_impl`, so its WAL was empty vs. the leader's populated → consensus divergence on any subsequent WAL-hash commitment.  Two new helpers on `FsProcesses` — `journal_write` and `journal_truncate` — centralize the (fd → cmode + canon_path) lookup and the append; `write_impl` no longer touches the WAL.  Cap-exceeded return here (`FSERR_QUOTA_EXCEEDED`) is deterministic: both sides encounter the cap at the same operation because both drive appends from the same args in the same order.
- **H-29-1** (`rho_runtime.rs`): `RhoRuntimeImpl` gained a `wal_snapshot: Arc<Mutex<Option<WalMark>>>` field; `create_soft_checkpoint` snapshots the WAL length via `Wal::snapshot_mark()` alongside the fd counter, and `revert_to_soft_checkpoint` calls `Wal::truncate_to(mark)` to discard any entries appended during a reverted deploy.  Pre-fix, a leader whose deploy reverted mid-execution would have journaled writes that no follower ever sees.  Regression pin: `fs_wal_spec::revert_soft_checkpoint_truncates_wal`.
- **H-29-2** (`wal.rs`): new constant `MAX_WAL_ENTRIES = 65_536` and `Wal::append` returns `Result<(), ()>` with `Err(())` on overflow; handlers translate to `FSERR_QUOTA_EXCEEDED`.  Prevents an adversarial deploy from growing the WAL without bound.  Regression pin: `wal::tests::wal_append_returns_err_at_cap`.
- **H-29-3** (`File.rho`, `Dir.rho`): `File.chmod`, `Dir.chmod`, `Dir.removeFile`, `Dir.removeDir`, `Dir.rename`, `Dir.copyFile` now fail closed with `FSERR_UNSUPPORTED` on Consensus caps.  Slice 29's WAL only journals fd-based Write/WriteAt/Truncate, so a path-based mutation on a Consensus cap has no WAL record — leader could apply and followers would diverge.  (`chown` was already gated in the slice-26 native handler.)  Regression pins: 6 tests in `file_dir_check` (one per method).
- **H-29-F2** (`rho_runtime.rs::reset`): `RhoRuntimeImpl::reset` now calls `Wal::clear()` after `seed_next_fd_from_state_hash`.  Defense in depth — all correctness paths already drain the WAL per-deploy (via the redesigned soft-checkpoint machinery), but a caller resetting to a state root without first draining now observes an empty WAL rather than ghost entries from the prior block.  Regression pin: `fs_wal_spec::reset_clears_wal`.
- **Per-deploy scoping API added** (`wal.rs`): `Wal::begin_deploy() -> WalMark` and `Wal::take_deploy_entries(mark) -> Vec<WalEntry>` provide the hook slice 30 will use to attach each deploy's WAL contributions to its ProcessedDeploy (or to a side-map keyed by deploy signature).  MVP does not yet wire this into `casper::rholang::runtime::play_deploy_with_cost_accounting` — that wiring is bundled with slice 30's on-chain commitment work because the schema of the per-deploy WAL attachment is a hard-fork question.  Unit tests in `wal.rs`: `wal_take_deploy_entries_drains_since_mark`, `wal_take_deploy_entries_empty_deploy_returns_empty`.
- **M-29-3 (partial-write correctness) deferred to slice 30:** the WAL records the REQUESTED byte length and hash of REQUESTED payload, not the actual `n` bytes written.  On a partial write the on-disk state is `n<len`; the FIP documents this as a caller-responsibility retry pattern.  The trade-off: recording REQUESTED bytes makes the WAL fully derivable from contract args, which is what makes leader/follower symmetric on the `is_replay` short-circuit (follower does NOT re-issue the syscall and therefore does not know `n`).  Slice 30's snapshot/replay design will decide whether to accept the partial-write hazard or restructure so the follower parses `n` out of `previous` and records the actual bytes-written hash.
- **ProcessedDeploy proto schema change deferred to slice 30:** attaching WAL entries to `ProcessedDeployProto` as a new field would be a hard-fork change and belongs alongside the on-chain WAL Merkle root commitment.  The redesign uses the per-deploy scoping API so slice 30 has the choice of proto extension vs. side-map.

**Redesign test coverage delta:** wal.rs unit 8/8 (was 4).  fs_wal_spec 11/11 (was 8).  file_dir_check 427/427 (was 421; added 6 H-29-3 pins).

**Original MVP delivery notes preserved below.**  New module `rholang/src/rust/interpreter/io/wal.rs` with `WalEntry` (op, path, extra_path, offset, length, payload_ref, mode_bits, owner, group), `WalOp` enum (Write, WriteAt, Truncate, Chmod, Chown, RemoveFile, RemoveDir, Rename, CopyFile — the last six are RESERVED for the follow-up slice), `PayloadRef::Hash([u8; 32])` (Blake2b256) + `PayloadRef::DeployRef { block_hash, deploy_index, arg_index }` (defined but not yet emitted), and `Wal` (`Arc<Mutex<Vec<WalEntry>>>` with append / snapshot / len / clear / is_empty methods).  Attached to `FileHandleTable` (which already rides through every `FsProcesses` clone via `Arc`) so handler closures reach the WAL via `self.handles.wal`.  **cmode threading:** `FileHandle` gained a `cmode: ConsensusMode` field captured at `fs_open` time; `fs_open`'s arity extended from 4 → 5 to accept the caller's cmode (with fail-closed C-26-F1 semantics — invalid cmode returns `FSERR_BAD_ARG` before the open).  `Dir.rho::openFileImplInner` updated to pass the cap's `cmode` to `fsOpen!(...)`.  **Journaling wired in FD-based writes:** `write_impl` (covers both `fs_write` and `fs_write_at`) and `fs_truncate` look up `(cmode, canon_path)` from the FileHandle via `handles.with_mut`, and — on successful syscall completion, if `cmode == Consensus` — append a `WalEntry` with `payload_ref = Some(PayloadRef::hash(&payload))` (for writes) or `None` (for truncate).  Non-Consensus caps skip the Blake2b hash cost entirely.  **Determinism:** Blake2b256 is cryptographic + deterministic; append order matches Rholang small-step semantics + is_replay cache; so the WAL is byte-identical across validators after processing the same block sequence.  **Deferred to follow-up slices (documented in `wal.rs` docstring):** (a) path-based mutations (`fs_chmod`, `fs_chown`, `fs_removeFile`, `fs_removeDir`, `fs_rename`, `fs_copyFile`) need signature extensions to accept caller cmode, mirroring slice-26's `fs_chown` threading — WalOp variants are reserved so the follow-up doesn't need enum surgery.  (b) `PayloadRef::DeployRef` optimization requires plumbing deploy-context (block_hash + deploy_index + arg_index) down through `fs_write` — bigger diff.  (c) Persistence + on-chain Merkle-root commitment + snapshot/replay machinery = slice 30.  **Tests (12 total):** 4 unit tests in `wal.rs` (payload_ref hash matches Blake2b256, append+snapshot, clone shares buffer, clear); 8 integration tests in `rholang/tests/fs_wal_spec.rs` (Consensus write appends entry with correct hash; Oracular write appends nothing; writeAt populates offset; truncate populates offset; multiple mutations append in insertion order; mixed Oracular+Consensus in one runtime only journals the Consensus; failed write appends nothing; bad-cmode open produces no handle → no WAL entry).  **Green results:** rholang io lib 94/94 (including 4 new wal + existing handle_table 15/15); rholang fs_wal_spec 8/8; rholang fs_native_urn_filter_spec 9/9; rholang fs_next_fd_seed_spec 4/4; rholang file_dir_check 421/421; casper lib 281/281; casper genesis integration 34/34.  Fmt + clippy clean.
- Slice 30 — Consensus-mode snapshots PB-M-15 **foundational MVP + review-round + slice-30b + slice-30b review-round all landed 2026-08-05.**

**H-P7-8 / H-25-COV-1 fix — populated-bundle emit shape (delivered 2026-08-05):** `format_bundle_for_rholang` was emitting `("<full_file_path>", "", ...)` for every File entry; `Fs.openFile`'s downstream chain (`openFileImplInner` → `fs_stat` → `safe_descend`) needs a non-empty `rel` for `safe_descend` to have a leaf to walk.  Pre-fix, every populated `oracle-static-file` / `consensus-static-file` entry cascaded to `[false, "FSERR_BAD_ARG", "empty relative path"]` — silent breakage across the whole populated-bundle case.  The empty-bundle spec never hit this because it short-circuited at "not in bundle" → `FSERR_UNSUPPORTED`; `file_dir_check.rs` inline bundles used handmade `(dir, filename)` tuples so didn't exercise the projection path either.
- **Fix: File entries emit `(parent_dir, filename)`.**  `canon_path.parent()` + `canon_path.file_name()` split at composer-time.  Dir entries stay `(canon_path, "")` — Dir caps root ON the provisioned path, not inside it.  BundleEntry shape is unchanged; only the composer's interpretation of the two Rholang tuple slots differs by `kind`.
- **Tests updated (5 in fs_genesis unit tests):** `format_bundle_single_file_entry`, `format_bundle_escapes_quote_and_backslash` (switched to Dir entry to keep the escape assertion meaningful), `compose_fs_genesis_source_injects_bundle_map`, `format_bundle_emits_consensus_mode_as_5th_tuple_element`, `compose_fs_genesis_source_with_mixed_consensus_modes_compiles`.  All 41 fs_genesis tests green.
- **New integration test:** `fs_generator_populated_bundle_installs_and_dispatches` in `fs_generator_spec.rs`.  Genesis with a populated bundle (real tempdir file, `BundleEntry::try_new` construction, `GenesisParameters.fs_bundle` populated); user Rholang looks up Fs URI, calls `openFile("nonexistent-name", {})` → asserts `[false, "FSERR_UNSUPPORTED", _]`.  This proves the populated-bundle genesis composition + user-scope Fs cap dispatch chain runs cleanly.
- **H-P7-8-E2E fix (delivered 2026-08-06):** the populated-NAME `openFile` path was hanging in the RhoSpec harness — root cause was NOT tokio/spawn_blocking as suspected but a *silent arity mismatch between `fs_native_def` registrations and post-slice-26 handler signatures*.  Slice 26 (2026-08-04) threaded `cmode` through 7 native handlers (`fs_stat`, `fs_entries`, `fs_rename`, `fs_copy_file`, `fs_remove_file`, `fs_remove_dir`, `fs_chmod`, `fs_chown`) but their `fs_native_def(...)` arity fields in `rho_runtime.rs` were never bumped to match.  The persistent receive installed on each fs-native fixed channel had the pre-slice-26 arity (3 for `fs_stat`, 5 for `fs_chown`, etc.); every send with the correct number of args silently didn't match → sent Datum sat forever in the tuplespace waiting for a matching consume that never appeared.  Diagnostic path: instrumented `produce_inner` to log produces on `byte_name(51)`, saw `data.len=4` land while the install trace showed `arity=3`.  Fix: bump 7 arities to match handler destructures (`fs_stat` 3→4, `fs_entries` 3→4, `fs_rename` 5→6, `fs_copy_file` 5→6, `fs_remove_file` 3→4, `fs_remove_dir` 4→5, `fs_chmod` 4→5, `fs_chown` 5→6).  Silent-breakage class: only tests that used mock syscalls (`file_dir_check.rs`) or pre-slice-26 arg counts (`fs_wal_spec.rs`'s `fs_write` on the unchanged 3-arity write handler) escaped detection — the RhoSpec harness populated-bundle path is the first test that exercises the post-slice-26 real-syscall chain end-to-end.  Test coverage now proves the full `Fs.openFile → openFileImpl → fs_stat + fs_open → File mint → File.readN → fs_read` chain against a real tempdir file.
- **Green results:** casper lib fs_genesis 41/41, casper genesis integration 9/9 (1 new — populated-bundle E2E now green with all 3 assertions passing: early-return, `[true, cap]` mint, `[true, bytes]` read), rholang file_dir_check 435/435 (mock-syscall path unaffected by arity bump — the 7 handler receives now match the send arities), rholang fs_wal_spec 23/23 (uses pre-slice-26 write path), rholang fs_native_urn_filter_spec 14/14.  Clippy clean under `-D warnings`.

**H-P7-6 root-path TOCTOU fix (delivered 2026-08-05):** the Phase 7 whole-review flagged that boot-time root canonicalization becomes stale if the root path is renamed / replaced with a symlink post-boot.  Investigation revealed the actual code shape differed from the review's description — safe_descend re-opens the root by path per syscall (not a long-lived boot fd) — but the underlying attack surface is real: `open_dir(root, false)` opens the root WITHOUT `O_NOFOLLOW`, so a post-boot symlink swap silently redirects subsequent syscalls into an attacker-controlled tree.  Fix:
- **`safe_descend` now opens the root with `O_NOFOLLOW`** (`open_dir(root, true)`).  If the root path is replaced with a symlink post-boot, the open fails with `ELOOP` (Linux) or `ENOTDIR` (macOS) → both map to `QuarantineError::SymlinkComponent`.
- **`open_dir` gains a macOS-style ENOTDIR fallback** mirroring the existing `openat_dir` disambiguation — `open(O_DIRECTORY|O_NOFOLLOW)` on a symlink returns `ENOTDIR` on macOS (the symlink isn't a directory) and `ELOOP` on Linux; both are surfaced as `SymlinkComponent` for consistent operator-facing errors.  New helper `is_symlink_at_path(&CString)` (absolute-path variant of `is_symlink_at`).
- **Consistency with boot invariant:** the provisioning validator already rejects any provisioned path that is a symlink at boot — so a legitimately provisioned root can never be a symlink.  Enforcing `O_NOFOLLOW` on the root open extends that invariant to every syscall over the process lifetime.
- **Explicit deferral (rename-and-recreate).** If an attacker does `mv /legit /legit.bak && mkdir /legit && populate`, the new `/legit` is a real directory with a different inode.  `O_NOFOLLOW` doesn't defend — a real directory doesn't get followed.  Full defense requires the provisioning layer to record boot-time `(dev, inode)` for each root and `safe_descend` to verify via `fstat` after open — documented as follow-up.  Practical mitigation today: operators mount consensus/oracle-static roots on filesystems the node user cannot write to (read-only bind mounts).
- **Test pin:** `safe_descend_rejects_root_replaced_with_symlink_post_boot` — creates a real root, does a sanity descend, then removes+symlinks the root to an attacker tree, and asserts the post-attack descend fails with `SymlinkComponent`.  Companion assertion that the attacker file itself is not reachable via the compromised path.
- **Green results:** rholang io lib 119/119 (was 118; +1 H-P7-6 pin), rholang io::path 13/13 (was 12; +1), fs_wal_spec 23/23, workspace clippy clean under `-D warnings`.

**Slice 30c correctness-gaps batch — M-29-3 + F-30-8 + F-30b-1/2/3 (delivered 2026-08-05):** the deferred correctness/doc items from slice 29/30/30b now dispatched.
- **M-29-3 (partial-write correctness):** RESOLVED.  Pre-syscall `journal_write` still records the REQUESTED bytes as a placeholder (preserves cap-check semantics).  Post-syscall, both leader and follower call the new `finalize_write_journal` helper: if `n < requested`, the placeholder is replaced via `Wal::update_last_entry_by_ack_hash(ack_hash, updated)` with `bytes[..n]`.  Leader extracts `n` from the syscall reply; follower extracts it from the cached `previous`.  Deterministic: both sides converge on identical WAL entries even under partial-write divergence.  Partial writes on Consensus caps also log a WARN so operators can surface underlying disk issues.  Pinned by 3 new `wal::tests`: `update_last_entry_by_ack_hash_replaces_matching_entry`, `update_last_entry_by_ack_hash_returns_false_when_no_match`, `update_last_entry_finalize_replaces_only_most_recent_match`.
- **F-30-8 (system-deploy WAL attribution):** RESOLVED via containment.  `play_system_deploy` (standalone-system-deploy path for CloseBlock, Slash, etc.) is now wrapped with a `WalDeployScope` whose Drop-path discard-drain prevents any Consensus WAL entries a system deploy might produce from leaking into the next user deploy's slice.  Currently no system deploy touches Consensus caps (they dispatch to PoS / vault contracts, none of which invoke fs-native URNs), but if a future system deploy is written to do so its WAL entries will be logged at debug on the discard-drain path.  Full block-level attribution (adding system-deploy WAL to the block aggregator with a proto extension for `ProcessedSystemDeploy`) is deferred as a bounded follow-up.
- **F-30b-1 (retention formula ratification):** ~~RESOLVED via docs~~ ~~superseded 2026-08-11~~ **SHIPPED 2026-08-23**: `NodeConfig.storage.consensus_fs_snapshot_retain: Option<usize> → usize`.  `#[serde(default)]` retained so already-shipped HOCON configs that don't set consensus provisioning still parse (get 0, unused when no consensus provisioning is present).  New `SnapshotConfigError::RetainTooSmall { retain }` variant rejects `retain < 2` when consensus provisioning is present with a diagnostic including sizing guidance (`retain = ceil(N / cadence) + 1`).  `build_snapshot_writer` signature promoted: `retain_override: Option<usize> → retain: usize`; the `saturating_mul(2)` fallback branch deleted.  See §PB-M-15.  26/26 snapshot_config tests pass (7 new / 4 deleted).
- **F-30b-2 (RwLock reconfig semantics):** RESOLVED via docs.  `RuntimeManager::set_fs_snapshot_writer` docstring now explicitly ratifies hot-reload as INTENTIONAL: post-boot operator adjustments (retention tuning, dir migration, snapshot disable) take effect on already-spawned runtimes without a node restart.  Consensus-safety note included: cadence is a Genesis-committed shard param (slice 30c Phase A), so hot-reload of the per-node `dir` / `retain` fields does not fork consensus.
- **F-30b-3 (BlockData::empty sentinel):** RESOLVED.  `BlockData::empty()` now returns `block_number = -1` instead of `0`.  Pre-fix a runtime spawned before `set_block_data` was called would appear to be at block 0 — a cadence hit for any cadence.  Was harmless only because empty-entries also skipped the write path; now the negative-block-number guard in `SnapshotWriter::maybe_write` deterministically skips the sentinel regardless of accumulated entries.  Pinned by `snapshot_writer_skips_block_data_empty_sentinel` which asserts `BlockData::empty().block_number < 0` AND that `maybe_write` on that value produces no snapshot AND no manifest entry.
- **Green results:** rholang io lib 118/118 (was 114; +4 new — 3 M-29-3 + 1 F-30b-3), rholang wal 17/17 (was 14; +3 M-29-3), fs_wal_spec 23/23, casper rholang::runtime 16/16.  Clippy clean under `-D warnings`.

**M-14 dedup — `lib_body` consolidation (delivered 2026-08-11).**  Option B (move to `rholang`, `casper` imports).  New module `rholang/src/rust/interpreter/rho_source.rs` holds the canonical `pub fn lib_body(&str) -> &str` lexer-aware brace-matcher (60 lines + 9 unit tests including the three previously casper-only cases: nested braces, trailing content past close, `in`-inside-identifier rejection).  `casper::genesis::contracts::fs_genesis` and `rholang::tests::file_dir_check` both import from there; the two hand-synced copies (M-P6-4 originally caught a divergence between them) are removed.  Both crates check clean; `rho_source::tests` 9/9; `casper::fs_genesis::tests` 37/37; `file_dir_check::with_libs_composes` 1/1.  Drift risk permanently closed at the source-of-truth layer.

**H-R3 fix — full integration (delivered 2026-08-05):** the PoC substrate landed the primitives; this integration wires them through the production path.  H-R3 is now resolved end-to-end.
- **`journal_write`, `journal_read`, `journal_truncate`** all take an extra `ack: &Par` parameter.  Each computes `ack_channel_hash(ack)` via new `handlers::ack_channel_hash` helper (uses `rspace_plus_plus::rspace::hashing::stable_hash_provider::hash(par)` — the same function rspace uses for `ProduceEvent.channel_hash`) and calls `Wal::append_with_ack(entry, hash_bytes)`.
- **6 call sites updated** across `fs_write`, `fs_write_at`, `fs_truncate`, `fs_read`, `fs_read_at` (both leader + `is_replay=true` branches).  All existing tests continue to pass — the leader/follower symmetry is preserved because both sides pass the same ack Par to journal_write.
- **`WalDeployScope::take_and_commit(&mut self, deploy_log: &[Event])`** — now takes the deploy's event log and calls `Wal::take_deploy_entries_in_log_order` instead of `take_deploy_entries`.  New helper `casper::rholang::runtime::produce_channel_hashes(deploy_log)` walks `Event::Produce` variants and extracts 32-byte channel_hashes for the drain-time reorder.
- **Both drain sites updated** in `play_deploy_with_cost_accounting` — success path (line ~671) and pre-charge-failure Ok path (line ~747).  Both now pass `&deploy_log` (already in scope via `mem::take(&mut eval_collector_state.event_log)`).
- **Drop-path discard-drain** stays on insertion-order `take_deploy_entries` — error paths discard the entries anyway, so their order doesn't matter for consensus.  Documented in `WalDeployScope::drop`.
- **All existing casper `WalDeployScope` tests** updated with a mechanical `scope.take_and_commit(&[])` pattern.  Empty-log input triggers the defense-in-depth path in `take_deploy_entries_in_log_order` (unmatched entries appended at end in insertion order), preserving prior test semantics.
- **Green results:** rholang lib 306/306 (was 305; up +1 from ambient), rholang io lib 114/114, fs_wal_spec 23/23 (including `wal_is_byte_identical_on_leader_and_follower` — still exercises leader/follower symmetry via `runtime.fs_handles.wal.snapshot()`), casper lib 294/294 (was 292; +2 cadence pins from Phase A).  Clippy clean under `-D warnings`.
- **H-R3 disposition:** RESOLVED.  All deploy-drain paths in production now emit WAL entries in canonical log order, deterministic across validators and re-executions regardless of tokio `Par` scheduling.  H-R2 disposition consequently: RESOLVED-BY-CONSTRUCTION — under log-order semantics the WAL is a projection of the event log, so any future hard-checkpoint of the tuplespace (which includes the event log) automatically covers the WAL.
- **Remaining cleanup deferrable to a housekeeping slice:** remove `Wal::append` (sentinel-hash path), remove `Wal::take_deploy_entries` (insertion-order path).  Both are still called by tests that don't set ack hashes; removing them requires updating those tests.  Non-urgent — the sentinel path is provably-safe defense-in-depth.

**H-R3 fix (option B) — log-order-derived WAL drain, PoC substrate (delivered 2026-08-05):** H-R3 is the Par-parallel WAL ordering nondeterminism: two runs of the same deploy under different tokio schedulings can populate the WAL Vec in different orders, giving different WAL roots — breaking any on-chain commitment.  Investigation surfaced that pure "reconstruct from log" (option B as originally sketched) is impossible because the event log records only channel_hashes, not args (args are hashed away in Produce events).  Revised design: handlers still construct WalEntries in memory, but store them keyed by ack-channel hash; at drain time, walk the deploy_log's Produce events, look up each Produce's channel_hash in the sidecar, emit in log order.  Log order is canonical per block (frozen when the leader publishes; followers consume verbatim), so re-ordered output is deterministic across validators and re-executions.
- **`Wal` gains an `ack_hashes: Arc<Mutex<Vec<[u8; 32]>>>` sidecar**, index-aligned with `entries`.  New `append_with_ack(entry, ack_hash)` records both; legacy `append(entry)` writes the sentinel `[0u8; 32]` for backwards compat.
- **`take_deploy_entries_in_log_order(mark, produce_channel_hashes)`** — new method that drains and reorders.  Builds an ack_hash → entry-index map for O(1) lookup, walks the log's produce channel_hashes in order, emits each matching entry once.  Defense-in-depth: entries whose sidecar hash never appears in the log get appended at the tail (nothing silently dropped).
- **Soft-checkpoint interaction**: `truncate_to(mark)` and `clear()` now also truncate the ack_hash sidecar to preserve index alignment across `revert_to_soft_checkpoint`.  Pinned by `ack_sidecar_stays_index_aligned_across_soft_checkpoint_revert`.
- **Tests (6 new in `wal::tests`):** `log_order_drain_permutes_insertion_order_to_match_log_order` (basic reorder), `log_order_drain_is_deterministic_across_insertion_permutations` (the H-R3 fix core — three different insertion orderings + same log walk = identical output), `log_order_drain_appends_unmatched_entries_at_end`, `log_order_drain_ignores_log_entries_without_matching_wal` (log noise from non-fs sends filtered), `log_order_drain_empty_mark_returns_empty`, `ack_sidecar_stays_index_aligned_across_soft_checkpoint_revert`.
- **Explicit deferrals** to the H-R3 integration follow-up:
  - Plumb the ack Par through every fs syscall handler (`fs_read`, `fs_read_at`, `fs_write`, `fs_write_at`, `fs_truncate`) — call `stable_hash_provider::hash(ack)` and pass to `append_with_ack` instead of `append`.
  - Extend `WalDeployScope::take_and_commit` to accept the deploy's event log and call `take_deploy_entries_in_log_order` instead of `take_deploy_entries`.
  - Extract the sequence of produce channel_hashes from the deploy_log at `play_deploy_with_cost_accounting`'s drain site — walk `deploy_log` for `Event::Produce(pe)` variants, extract `pe.channels_hash` bytes.
  - Once every production drain path uses the log-order method, remove the legacy insertion-order `take_deploy_entries` and the `append` (no-ack sentinel) code paths.
- **Green results:** rholang wal 14/14 (was 8; +6 log-order tests).  Clippy clean under `-D warnings`.  No other tests touched — the new method runs alongside the existing behavior.

**Slice 30c Phase C — join-protocol manifest substrate (delivered 2026-08-05):** joining validators need a way to enumerate which snapshots a peer has on disk without listing directories or probing every possible content-hash.  Phase C lands the manifest file substrate + empty-slice sentinel (F-30b-4).  Network transport still deferred to a follow-up (30c-4).
- **`<snapshot-dir>/manifest.jsonl`** — append-only file with one JSON line per cadence-hit block: `{block_number, root, entries, ts_ms}`.  Hand-rolled parser (no serde) so the wire format is reproducible from other languages / operator diagnostic scripts.  Data entries carry `"root": "<hex>"`; empty-sentinel entries carry `"root": null`.
- **`SnapshotWriter.maybe_write` appends per cadence hit** — both data slices AND empty-sentinel slices.  Manifest append is best-effort (failures log at warn but don't abort the write path — the snapshot file is already durable; missing manifest lines can be reconstructed by directory scan).
- **F-30b-4 empty-slice sentinel resolved.**  Pre-30c an empty cadence hit was a silent skip — indistinguishable from a cadence miss to a joining validator.  Post-Phase-C, empty hits emit a sentinel line so joiners can prove they haven't missed a snapshot boundary.  No `.wal` file is written for empty slices (all empty payloads hash identically; one file per empty slice would waste disk).
- **`read_manifest(dir) -> Result<Vec<ManifestEntry>>`** — for peers to publish + for catch-up clients to plan fetches.  Missing manifest returns empty vec (valid partial view for a joining validator); corrupt line surfaces as `Io(InvalidData)` with the line number.
- **`ManifestEntry::{to_line, from_line}`** — round-trippable serialization; strict-schema parser rejects wrong-length root hex, unknown keys, missing fields.
- **Explicit deferrals (30c-4 or later):** network transport (`GET /snapshots/<root_hex>` or peer-level RPC) — requires comm-crate integration, new protobuf messages, retry / peer-selection, state machine for catch-up progress; manifest signing / attestation — pending threat-model review; automatic reconstruction from directory scan if manifest is absent — currently missing manifest = no discovery.
- **Tests (10 new in `snapshot.rs`):** entry round-trip data + empty, append/read preserves order, absent-file returns empty, corrupt-line surfaces error with line number, `maybe_write` sentinel-on-empty pin, `maybe_write` data-entry pin, cadence-miss no-manifest-touch, wrong-length root hex rejection, missing-field rejection.  Plus 1 updated existing test (`snapshot_writer_skips_empty_entries_even_on_cadence_hit`) — now asserts no `.wal` file + 2 sentinel manifest entries.
- **Green results:** rholang io lib 99/99 (was 98; +10 new manifest tests, -1 old test replaced, net +9 that adds up to 99 with existing shape).  Actual counts: `io::snapshot` 49/49, fs_wal_spec 23/23, whole `io::` 99/99.  Clippy clean under `-D warnings`.

**Slice 30c Phase A — shard-Genesis cadence + HOCON deprecation (delivered 2026-08-05):** first half of slice 30c.  Establishes cadence as a shard-wide parameter without yet moving the WAL-write hook.
- **`Genesis.consensus_fs_snapshot_cadence: Option<u64>`** added.  `Hash` impl updated to include it — two Genesises with different cadence values now hash-differ (a shard whose operators disagreed on cadence would silently pass Genesis-hash agreement pre-30c and only diverge at finalization; now caught at genesis).  10 test/production Genesis construction sites updated to default `None`.
- **HOCON `storage.consensus-fs-snapshot-cadence` deprecated** via `#[deprecated]` attribute.  The three call sites (`setup.rs` boot read, `config_mapper.rs` + `diagnostics/tests.rs` struct init) gated with `#[allow(deprecated)]`.  Setup boot logs a warning if the deprecated key is set.  The key is retained in the schema for backwards compatibility; a follow-up slice will remove it entirely.
- **HIGH-4 boot wiring kept in place, temporarily.**  `setup.rs` still reads the deprecated HOCON cadence as a transitional bridge — moving the wiring to post-Genesis-load is Phase B.  Without the bridge, slice 30c-1 would regress HIGH-4 (validators would boot with no SnapshotWriter attached at all).
- **Tests (2 new in `genesis::genesis::tests`):** `genesis_hash_differs_when_only_cadence_differs` (two Genesises differing only in cadence hash-differ), `genesis_hash_differs_when_cadence_toggles_none_to_some` (opt-in vs opt-out shards produce distinct hashes).  Existing `genesis_hash_ignores_fs_bundle_order` and `genesis_hash_differs_when_only_cmode_differs` still pass (Genesis Hash impl is manually written to preserve sorted-bundle invariant + include every consensus-relevant field).
- **Explicit deferral to slice 30c-2:** the actual LFB-hook move (`SnapshotWriter.maybe_write` from `play_deploys_for_state` per-block into `finalization_runner`'s `new_lfb_found_effect`) is deferred.  It requires: (a) changing `play_deploys_for_state` signature to return `Vec<WalEntry>`, (b) new WAL cache on `RuntimeManager` keyed by block hash (populated by the upstream caller that knows the block hash), (c) moving the maybe_write call into the finalization effect closure, (d) sourcing cadence from the loaded `Genesis` at that call site, (e) cache eviction on orphaned blocks, (f) rewriting several WAL integration tests that assume per-block snapshot semantics.  Phase B is a full slice on its own.
- **Green results:** rholang io lib 98/98, node lib 325/325, casper genesis 47/47 (including 2 new cadence hash pins).  Clippy clean under `-D warnings`.

**Slice 35 — MED-5 minimum-viable retain override (Phase 7 whole-review FIPS partial-fix; delivered 2026-08-05):** the `retain = cadence * 2` heuristic scales quadratically in cadence (retention-in-blocks = `2 * cadence²`), which is almost certainly wrong at both ends of the cadence range.  Full ratification requires deciding what cadence *means* in a DAG — a substantive design question deferred to slice 30c (join-protocol design).  MED-5's minimum-viable ratification lands the operator escape hatch now:
- **`storage.consensus-fs-snapshot-retain: Option<usize>`** new per-node HOCON key.  `Some(n)` overrides the built-in heuristic; `None` (default) preserves the existing `cadence * 2` formula for backwards compatibility.
- **`build_snapshot_writer` signature extended** with a `retain_override: Option<usize>` parameter.  Override wins when set; falls back to the heuristic when unset.  Retain floor of 2 still applies to both paths (never keep fewer than one prior + current snapshot — data-availability disaster for joining validators).
- **Docstring on the new HOCON key** explains sizing guidance (`ceil(desired_join_window_blocks / cadence) + 1`) and calls out that the built-in default is a placeholder heuristic pending slice 30c.
- **Cadence-in-DAG semantics deferred to slice 30c.**  User pointed out that `block_number % cadence == 0` isn't well-defined in a multi-parent DAG where sibling blocks can share a `block_number`.  The right semantic is LFB-cadence: snapshots fire when the `LastFinalizedBlock` pointer's `block_number` crosses a cadence multiple.  All validators observe the same LFB sequence (safety guarantee), so all decide identically.  Implementation moves the `SnapshotWriter.maybe_write` call site out of `play_deploys_for_state` (which runs per-block including non-finalized tips) into the finalization runner's `new_lfb_found_effect` closure (fires when the LFB advances).  Cadence itself moves to the `Genesis` struct as a shard-wide parameter.  This is slice-30c-scope surgery (Genesis field addition, boot-wiring relocation, finalization-runner hook, joining-protocol design) that shouldn't be smuggled into a MED-5 ratification.
- **Tests (4 new in `snapshot_config.rs`):** `build_snapshot_writer_retain_override_wins_over_default` (explicit override honored), `build_snapshot_writer_retain_override_none_falls_back_to_default` (backwards compat), `build_snapshot_writer_retain_override_below_floor_is_clamped_to_two` (0 or 1 clamped up), `build_snapshot_writer_retain_override_ignored_when_no_provisioning` (retain override can't conjure a writer without provisioning).
- **F-30b-1 disposition:** partially resolved (retain is now operator-tunable + documented + one sizing formula given in the docstring).  Full ratification of the default heuristic pending slice 30c's cadence-in-DAG design.
- **Green results:** node lib 325/325 (was 321; +4 slice-35).  Workspace build + fmt clean.

**Slice 34 — snapshot format version byte + hard-fork surface catalog (MED-1 FIPS fix from Phase 7 whole-review; delivered 2026-08-05):** the WAL / snapshot encoding had seven consensus-critical decisions scattered across `encode_entry`, `op_tag`, `PayloadRef`, and the module-level docstring — but no leading version byte and no catalog.  Any future format change would require a lockstep validator upgrade (stragglers would silently mis-decode), and a maintainer refactoring one item might not realize the whole surface was in play.
- **`SNAPSHOT_FORMAT_VERSION: u8 = 1`** added as a module-level pub constant.  `encode_wal_slice` now prepends the version byte before the entry count.  Layout: `[version: u8][count: u32-be][entry × count]`.
- **`read_snapshot_bytes` validates the version** — new `SnapshotError::UnsupportedVersion { got, supported }` and `SnapshotError::Truncated { got, need }` variants.  Version check runs after Blake2b256 hash verification as defense-in-depth (even if root check somehow passed, a bogus version byte fails clean).  Enables joining-validator scenarios where an older binary sees a snapshot from a newer network to surface a clean error rather than mis-decoding.
- **Hard-fork surface catalog docstring** added as a new `# Hard-fork surface catalog (MED-1, slice 34)` section in the module header.  Enumerates 8 consensus-observable surfaces: (1) format version byte, (2) op tag bytes, (3) hash function = Blake2b256, (4) length-prefix widths, (5) field widths / endianness, (6) `PayloadRef` variant tags, (7) field order inside `encode_entry`, (8) path encoding.  The catalog is a MAINTAINER contract: adding a consensus-observable surface means extending this list AND the pin test.
- **Golden hex re-pinned.**  Pre-slice-34 hash was `06a8ce93...b825`; post-slice-34 hash is `532eea90...38b2` — the version byte is added consensus commitment content, so the golden hex change is the correct hard-fork signal.  Test docstring records the pre-fix value for archaeology.
- **Byte-offset regression tests updated.**  `encode_entry_uses_op_tag_values` and `deploy_ref_encoding_is_big_endian_and_field_order_is_stable` recalibrated for the +1 byte offset from the version prefix.
- **Tests (5 new + 3 updated):** `encoded_slice_starts_with_format_version_byte`, `read_snapshot_bytes_accepts_current_version`, `read_snapshot_bytes_rejects_unknown_version` (fabricates a v99 blob, computes its hash, writes it, and asserts `UnsupportedVersion` on read), `read_snapshot_bytes_rejects_truncated_blob` (0-byte blob → `Truncated`), `hard_fork_surface_catalog_is_pinned` (scans module source for the 8 catalog headings — a regression that removes an item from the docstring fails here, forcing maintainers to acknowledge the surface).  Updated: `empty_slice_encodes_to_version_byte_plus_four_zero_bytes` (was `..._to_four_zero_bytes`), `encode_entry_uses_op_tag_values` (byte offsets), `deploy_ref_encoding_...` (byte offsets).
- **Green results:** rholang io lib 98/98 (was 93; +5 slice-34); rholang fs_wal_spec 23/23 (regression through `wal_to_snapshot_end_to_end_round_trip` which uses `encode_wal_slice` + `read_snapshot_bytes` — both now flow through the version byte).  Workspace build clean.  Fmt clean.

**Slice 33 — wire SnapshotWriter into node boot (HIGH-4 FIPS fix from Phase 7 whole-review; delivered 2026-08-05):** slice 30b shipped `build_snapshot_writer` + `RuntimeManager::set_fs_snapshot_writer` but the plumbing task to actually call them from `node::runtime::setup.rs` was punted to "slice 30c" and never landed.  As shipped, every validator ran with `fs_snapshot_writer = None`, so `SnapshotWriter::maybe_write` was never invoked in the `play_deploys_for_state` code path — PB-M-15's joining-validator story was nonfunctional in production.
- **Boot integration** added in `node/src/rust/runtime/setup.rs` immediately after `RuntimeManager::create_with_history`: merge provisioning via `merge_and_validate`, build the writer via `build_snapshot_writer(&merged, conf.storage.consensus_fs_snapshot_cadence, conf.storage.consensus_fs_snapshot_dir.as_deref())`, and attach it via `runtime_manager.set_fs_snapshot_writer(writer).await`.  Validation errors panic at boot with the operator-facing diagnostic; the empty-provisioning path attaches `None` (log at `debug` level).  Attaching a real writer logs at `info` with cadence + dir so operators can confirm at startup.
- **The H-30-1 `#[ignore]` placeholder is now a real test.**  `boot_pipeline_calls_build_snapshot_writer` in `snapshot_config.rs::tests` used to `panic!("boot has not yet been wired")` behind `#[ignore]`.  Post-slice-33 it reads `setup.rs` source and asserts the two boot-call needles (`build_snapshot_writer` and `set_fs_snapshot_writer`) are present.  A file-scan is a heavy match for a config test, but the alternative (spinning up a full node in-test) is disproportionate; the scan catches any regression that removes the boot call.
- **Merged-provisioning duplication note.**  `merge_and_validate` runs twice at boot now: once here for snapshot-writer construction, once inside `CasperLaunch` for the bundle handoff.  The two sites are independent (this one panics on validation failure with a snapshot-config-specific message; the CasperLaunch site panics with the bundle-handoff message).  Kept intentionally rather than plumbing the merged bundle through more layers — the merge is cheap (HashMap iteration + char rejection), and independence means a future refactor of either site doesn't break the other.  A follow-up slice may hoist the merge to a single earlier site if the duplication becomes structural noise.
- **Green results:** node lib 321/321 (was 320+1 ignored; H-30-1 test is now running instead of ignored/panicking).  Workspace build clean.  Fmt clean.

**HIGH-3 (PB-B-3 `insertVersion` for `rho:io:fs:1.0.0`) — RESOLVED (2026-08-24):** FsGenesis now invokes `insertVersion("serve", "fs", "1.0.0", fs, ...)` at genesis; the fs cap is resolvable via `lookupVersion` on `rho:serve:1.0.0:<FS_GENERATOR_PUB_KEY_HEX>:fs:1.0.0` in addition to the legacy `insertSigned` URI.  The 2026-08-05 concern — that supporting `new x(``rho:io:fs:1.0.0``)` at normalization time requires a normalizer-side alias layer — turned out to be scope-independent: `lookupVersion` (runtime API on the v1 registry) already covers deploy-time lookups without normalizer changes, and callers who want `new`-style URN binding get it via `new x(``rho:serve:1.0.0:<hex>:fs:1.0.0``)`.  The FIP-canonical `rho:io:fs:1.0.0` shape (as a bare alias of the serve URN) still needs the URN-parser extension + normalizer alias layer described in the 2026-08-05 note — that's a separate slice.

**Slice 32 — read-hash journaling (PB-M-14 read side, HIGH-2 FIPS fix from Phase 7 whole-review; delivered 2026-08-05):** the plan's PB-M-14 language (§Consensus-mode filesystem WAL) commits to journaling reads that consume file bytes so replay is byte-identical, but slices 29/30 only journaled MUTATIONS.  Slice 32 closes the gap.
- **`WalOp::Read` / `WalOp::ReadAt`** added to the enum (tags 10 and 11; op-tag stability preserved — Write/WriteAt/Truncate/Chmod/Chown/Remove*/Rename/CopyFile keep tags 1-9).  `snapshot::op_tag`, `op_tags_are_stable`, and `encode_entry_uses_op_tag_values` extended.  The golden-hex test (`compute_wal_root_golden_hex`) is unchanged because it uses a Write entry — adding new op variants doesn't change existing entries' encoding.
- **`journal_read`** helper on `FsProcesses` (mirrors `journal_write` / `journal_truncate`).  Looks up `(cmode, canon_path)` via `handles.with_mut(fd, …)` and, on Consensus caps only, appends a `Read` / `ReadAt` entry with `offset` (None for sequential, `Some(off)` for positional), `length = returned_bytes.len()`, and `payload_ref = PayloadRef::Hash(Blake2b256(returned_bytes))`.  Non-Consensus caps and missing fds are silent no-ops.
- **Leader path.**  `fs_read` and `fs_read_at` call `journal_read` after `read_impl` returns, using `extract_ok_bytes(reply)` to extract the successful bytes payload.  Error replies (bad fd, quota exceeded, syscall failure) short-circuit `extract_ok_bytes` to `None` and produce no WAL entry — mirrors `failed_write_does_not_append_wal_entry` semantics.
- **Follower path (leader/follower WAL symmetry).**  The `is_replay = true` branch of `fs_read` / `fs_read_at` does NOT re-execute the syscall — the tuplespace `previous` cache already supplies the correct return value.  Instead, the follower runs `extract_ok_bytes(previous)` to recover the leader's bytes and calls the same `journal_read` — appending a byte-identical WAL entry.  This is the counterpart to slice 29's C-R1 fix for writes.  New helper `extract_ok_bytes(previous: &[Par]) -> Option<Vec<u8>>` in `response.rs`.
- **Semantics.**  The WAL now captures every consensus-observable filesystem operation: mutations that change disk state (Write/WriteAt/Truncate) AND observations that feed the tuplespace (Read/ReadAt).  Per-deploy WAL byte-identity across leader and follower is preserved, so the per-block WAL-root commitment in `play_deploys_for_state` remains valid.  A joining validator whose reconstructed disk state produces different `fs_read` bytes than the leader recorded will surface as a WAL-root divergence at block-verification time rather than a silent tuplespace fork downstream.
- **What's still deferred to a follow-up slice:** stat/exists/size-side journaling.  Under the current design, `fs_stat`/`fs_exists`/`fs_size` results are derived from the reconstructed disk state (writes + truncates replayed against a base image), so leader/follower agreement on those return values follows from write-side WAL byte-identity.  A future slice may add explicit journaling for defense-in-depth against non-write disk-state mutations (external processes touching consensus-provisioned files).
- **Tests (6 new in `fs_wal_spec.rs`):** `read_on_consensus_cap_appends_read_wal_entry`, `read_at_on_consensus_cap_appends_read_at_entry` (positional offset pin), `read_on_oracular_cap_does_not_append_wal` (parity with writes), `read_wal_is_byte_identical_on_leader_and_follower` (the core symmetry invariant, via `create_leader_and_follower` + `check_replay_data`), `read_returning_zero_bytes_still_appends_wal_entry` (EOF/short-read observability), `failed_read_does_not_append_wal_entry` (parity with `failed_write_does_not_append_wal_entry`).
- **Green results:** rholang io lib 93/93 (op_tags_are_stable now pins 11 variants; encode_entry_uses_op_tag_values now iterates all 11); rholang fs_wal_spec 23/23 (was 17; +6 slice-32); rholang file_dir_check 435/435 (no regression from adding read journaling under existing test paths).  Fmt clean.

**Phase 7 whole-review round non-FIPS fixes (2026-08-05):** whole-Phase-7 review (slices 21-31) landed the following non-FIPS fixes; FIPS items are deferred to a subsequent discussion round.
- **H-P7-5 (High): `disable_fs_native_urn_filter` / `enable_fs_native_urn_filter` bare-toggle pattern leaked exemption on panic.**  Refactored to an RAII `FsNativeUrnFilterExemption` guard whose `Drop` re-enables the filter unconditionally.  Guard holds `Arc<AtomicBool>` clone (not `&RhoRuntimeImpl` borrow) so callers retain `&mut self` on the runtime for subsequent `create_checkpoint` calls that need to mutate.  `casper::rholang::runtime::play_deploys_for_genesis`, `replay_runtime::replay_deploys`, and `RhoReporterCasper::replay_deploys` (H-P7-7 mirror) all updated to use the guard with explicit `drop(_filter_exemption)` before the subsequent mut-borrow.  Pinned by 4 new tests in `rholang/tests/fs_native_urn_filter_spec.rs`: `raii_guard_reenables_filter_on_drop`, `raii_guard_reenables_filter_on_panic`, `raii_guard_explicit_drop_reenables_filter`, `raii_guard_spans_multiple_awaits_and_reenables`.
- **H-P7-7 (High): reporting_casper.rs did not mirror the URN-filter exemption.**  Reports of the genesis block would fail because `RhoReporterCasper::replay_deploys` re-executes the FsGenesis ProcessedDeploy which binds `rho:io:fs:native:*` URNs.  Fix mirrors the primary `replay_deploys` pattern via the new `FsNativeUrnFilterExemption` guard, gated on `!with_cost_accounting`.
- **M-P7-1 (Medium): snapshot write blocked the tokio worker.**  `play_deploys_for_state`'s `SnapshotWriter::maybe_write` call executes `std::fs::write` + `sync_all` + `rename` + parent-dir fsync — synchronous I/O that can be seconds on slow disks.  Fix: clone writer + entries out of the RwLock read guard, drop the guard, dispatch the blocking work via `tokio::task::spawn_blocking`.  This also unblocks a concurrent `RuntimeManager::set_fs_snapshot_writer` awaiting the write lock.
- **M-P7-2 (Medium): `prune_snapshot_dir` followed symlinks via `entry.metadata()`.**  A symlink pointing at a large file would be counted as "recent" even though pruning a symlink is cheap.  Fix: switched to `entry.file_type().is_symlink()` for kind detection + `symlink_metadata()` for mtime — symlinks are pruned by their own age, not their target's.
- **M-P7-3 (Medium): bucket-overlap check did not normalize paths.**  Two provisioning entries for `/etc/app/./config` and `/etc/app/config` would fail to trigger the overlap warning.  Fix: `check_bucket_disjointness` normalizes both paths via the shared `normalize_for_compare` helper (promoted to `pub(crate)`).
- **M-P7-4 (Medium): `project_bundle` sort stability.**  When two entries collide on logical name (defense-in-depth after slice 23's cross-bucket check), the sort was non-deterministic.  Fix: added tie-break on `consensus_mode` then `canon_path` in the projection sort.
- **L-30-COV-1 (Low): 20ms sleep in retention tests was flaky on macOS APFS.**  APFS's mtime granularity can be up to 1s; the 20ms sleep between writes made pruning-order tests race.  Fix: bumped to 1100ms in the two affected retention tests.
- **L-31-COV-1 (Low): missing positive-pin that `rho:system:*` URNs pass the fs-native filter.**  Added `system_urns_pass_through_the_filter` in `fs_native_urn_filter_spec.rs`.  A future refactor broadening the prefix check would fail this test loudly.
- **L-P7-1 (Low): `stat_record` kind bundle strings unpinned.**  Rholang branches on the exact strings `"file"` / `"directory"` / `"symlink"` / `"other"`; a rename would silently break Dir.openFile's stat-verify.  Added `stat_record_kind_bundle_pins_wire_strings` in `rholang/src/rust/interpreter/io/stat.rs`.
- **L-30-COV-2 (Low): reporting-runtime snapshot bypass undocumented.**  Reports are read-only traces and MUST NOT trigger snapshot writes.  Added a module-level docstring on `RhoReporterCasper::replay_deploys` clarifying that the reporting runtime's `fs_snapshot_writer` slot is never populated in production, so admin-triggered reports don't perturb the primary chain's snapshot cadence.
- **H-30-COV-1/3/4 (High coverage gaps): end-to-end WAL→snapshot pipeline tests.**  Three new tests in `fs_wal_spec.rs`: `wal_to_snapshot_end_to_end_round_trip` (Consensus write → WAL entries → `SnapshotWriter::maybe_write` → on-disk file → `read_snapshot_bytes` byte-identity), `wal_snapshot_not_written_on_cadence_miss` (cadence guard), `wal_snapshot_retention_bound_holds_across_writes` (retention across multiple cadence hits).

**Phase 7 whole-review deferrals to follow-up slices (all documented in-code):**
- **H-P7-6 (High): root-path TOCTOU via long-lived boot fd.**  The provisioning validator opens root fds at boot and re-uses them for the process lifetime.  A malicious `rename(rootDir, symlink_to_attacker)` between validator startup and first request would let an unrelated tree serve as the sandbox root.  Fix requires refactoring the root-fd management to re-open + re-canonicalize per-request (or at least periodically) — its own slice with proto-level review.
- **H-P7-8 / H-25-COV-1 (High): populated-bundle end-to-end test uncovered a genuine gap** in `Fs.openFile` for consensus-static-file bundle entries: `project_bundle` sets `canon_path=fullFilePath` + `rel=""`, but `openFileImplInner` → `safe_descend(root, "")` fails with `QuarantineError::Empty`.  Test placeholder + gap docstring landed in `fs_generator_spec.rs`.  Fix is a design decision (change `project_bundle` to emit `(parent, filename)` OR special-case `rel==""` in `safe_descend`) that wants its own review round; tracked as H-P7-8-DEFERRED.
- **H-26-COV-1, H-21-COV-1** — DELIVERED 2026-08-06 (post-H-P7-8-E2E, when the E2E scaffold was in place).  Two additive tests close the gap:
  - **H-21-COV-1** — `hocon_parse_through_project_bundle_full_pipeline_happy_path` in `node/src/rust/configuration/provisioning_merge.rs`.  Real tempdir with 4 real filesystem entities (1 file + 1 dir in each of oracle-static and consensus-static buckets), realistic HOCON block spanning all four buckets, run through `hocon::HoconLoader` -> `merge_and_validate` (real syscalls: canonicalization, is_symlink, hard-link, kind-match) -> `project_bundle`, assert 4 `BundleEntry` outputs with correct kind + cmode + canon_path + mode.  Existing tests either used `/etc/does-not-exist` paths (error paths only) or bypassed HOCON entirely (struct-literal fixtures); this pins the happy path from operator-writable HOCON all the way to genesis-consumable bundle.
  - **H-26-COV-1** — `fs_generator_consensus_cmode_routes_through_native_dispatch` in `casper/tests/genesis/contracts/fs_generator_spec.rs`.  Genesis with a `BundleConsensusMode::Consensus` bundle entry (as though operator declared `consensus-static-files { ... }`), user Rholang opens the cap and invokes `File.chmod`, asserts the reply matches the Slice 29 H-29-3 short-circuit message ("chmod not su...") rather than the write-mode gate ("chmod requires a write-capable mode").  The distinction is what proves the cmode plumbed end-to-end: cmode is checked BEFORE the write-mode gate in `File.rho` line 462, so a "consensus" cell fires the short-circuit even on the "r"-provisioned file; if any layer had defaulted to "oracular", we'd hit the write-mode gate instead.  Complements the existing 15 `resolve_cmode` unit tests + 4 `stat_record` unit tests + 9 mock-syscall integration tests in `file_dir_check.rs` by proving the FULL pipeline (BundleConsensusMode -> format_bundle_for_rholang -> Fs.openFile -> openFileImpl -> File constructor -> cmodeP cell -> method dispatch) actually routes to the consensus branch under real syscalls in the RhoSpec harness.
  - **Green results:** node lib 326/326 (was 325, +1 for H-21-COV-1); casper genesis integration 10/10 (was 9, +1 for H-26-COV-1); no regressions in existing suites.
- **L-P7-2/3** (informational): fd birthday collision at ~130 years, pid wrap negligible — documented already.

**Slice 30b review-round fixes (2026-08-05):** three-agent security / FIPS / test-coverage review of slice 30b surfaced 2 Criticals (both integration-test gaps), 5 Highs, 8 Mediums.  Fixes:
- **C-30b-1 (Critical: play_deploys_for_state aggregation untested).**  Added `play_deploys_aggregation_composition_writes_correct_snapshot` and `play_deploys_aggregation_preserves_deploy_scan_order` in `casper/src/rust/rholang/runtime.rs`.  The first exercises the exact composition — 3 mocked deploys → `WalDeployScope::take_and_commit` → `Vec::extend` aggregator → `compute_wal_root` → `SnapshotWriter::maybe_write` → on-disk verification — without full RuntimeManager weight.  The second pins deploy-scan order as consensus-observable (A-then-B ≠ B-then-A).
- **C-30b-2 (Critical: RuntimeManager set + spawn attach untested).**  Added 4 `snapshot_writer_wiring_tests` in `casper/src/rust/util/rholang/runtime_manager.rs`: set-before-spawn visible, set-AFTER-spawn also visible (the H-30b-2 core property), multiple runtimes share the slot, replay runtimes also share.
- **H-30b-1 (High: u64 overflow in retention).**  `snapshot_config::build_snapshot_writer` now uses `cadence.saturating_mul(2).try_into().unwrap_or(usize::MAX).max(2)`.  Pinned by `build_snapshot_writer_retain_saturates_on_cadence_overflow` and `build_snapshot_writer_retain_saturates_at_wrap_boundary`.
- **H-30b-2 (High: RwLock spawn-time cached staleness).**  Refactored `RhoRuntimeImpl.fs_snapshot_writer` from `Option<SnapshotWriter>` to `Arc<tokio::sync::RwLock<Option<SnapshotWriter>>>`.  New `RhoRuntimeImpl::share_fs_snapshot_writer` swaps in a shared Arc.  `RuntimeManager::spawn_runtime` / `spawn_replay_runtime` now call `share_fs_snapshot_writer(self.fs_snapshot_writer.clone())` instead of caching a per-runtime snapshot.  `play_deploys_for_state` reads via `.read().await` on every call — boot-time sets are live to every runtime.  Pinned by `manager_set_after_spawn_still_visible_to_runtime`.
- **H-30b-3 (High: O_EXCL semantics unasserted).**  Added `write_snapshot_never_truncates_existing_tmp_files` — pre-places a decoy at a `.wal.tmp` path and confirms `write_snapshot` leaves it untouched.
- **H-30b-4 (High: log field schema unpinned).**  Added OPERATOR-VISIBLE LOG SCHEMA comment at the `tracing::info!` site in `play_deploys_for_state` documenting field names (`n_entries`, `block_wal_root`) as stability contracts.
- **H-30b-5 (High: multi-snapshot concatenation semantics).**  Added `multi_snapshot_concat_matches_ordered_entry_replay` — pins the log-structured replay semantic: joining validators apply entries per-slice in order; per-slice roots are content-addressed independently.
- **M-30b-3 (Medium: .wal.tmp cruft).**  New `sweep_stale_tmp_files(dir, older_than_secs)` in `snapshot.rs`.  Pinned by `sweep_stale_tmp_files_removes_old_but_keeps_recent` and `sweep_stale_tmp_files_ignores_non_tmp_files`.
- **M-30b-4 (Medium: file mode leak).**  `write_snapshot` now explicitly sets `.mode(0o644)` on Unix so snapshot file permissions do not leak the leader's umask.  Pinned by `write_snapshot_sets_explicit_0o644_mode`.
- **M-30b-5 (Medium: dir-fsync silent).**  Both parent-dir-fsync failure paths now log at `tracing::debug` with the parent path + error, so operators can observe fs-support issues without being spammed at info level.
- **M-30b-6 (Medium: cadence boundary tests missing).**  Added `snapshot_writer_cadence_hits_multiples_of_cadence` (5, 10, 15, 100, 1000 vs 1, 4, 6, 9, 11, 999) and `snapshot_writer_handles_large_block_numbers` (block 42M with cadence 1M).
- **M-30b-7 (Medium: retention edges).**  Added `snapshot_writer_retain_zero_prunes_all_after_each_write` and `snapshot_writer_retain_max_keeps_everything`.

**Explicit deferrals to slice 30c:**
- **F-30b-1 (FIPS Medium): retention formula justification.** `retain = cadence * 2` is a heuristic; slice 30c can add explicit `storage.consensus-fs-snapshot-retain` config key or amend PB-M-15 to ratify the formula.
- **F-30b-2 (FIPS Medium): RwLock reconfiguration semantics.**  H-30b-2 refactor allows hot-reload of the writer config via `RuntimeManager::set_fs_snapshot_writer` post-boot.  Slice 30c documents whether that's intended behavior.
- **F-30b-3 (FIPS Low): BlockData::empty block_number=0.**  A runtime spawned before `set_block_data` runs sees block 0 (a cadence hit for any cadence).  Currently harmless because empty-entries skip prevents a real write; slice 30c may change `BlockData::empty()` to `block_number = -1` as a sentinel.
- **F-30b-4 (FIPS Low): empty-slice snapshot skip.**  Joining validators cannot distinguish "block had zero mutations" from "cadence miss".  Slice 30c may add a distinguished empty-slice sentinel or a manifest file.

**Slice 30b round-2 test coverage delta:** rholang io::snapshot 34/34 (was 25; added 3 tmp-sweep, 2 cadence boundary, 2 retain edges, 1 multi-snapshot concat, 1 O_EXCL semantics, 1 file-mode = 10 new).  node snapshot_config 23/23 + 1 ignored (was 21+1; added 2 overflow-saturation tests).  casper rholang::runtime 12/12 (was 10; added 2 aggregation tests).  casper snapshot_writer_wiring_tests 4/4 (new).  Regression: fs_wal_spec 14/14, file_dir_check 435/435 all green.  Fmt + clippy clean.



**Slice 30b MVP (2026-08-05):** ships the in-process pieces that don't require hard-fork proto changes.
- **F-30-12 (fsync before rename):** `write_snapshot` now `sync_all`s the tmp file before rename, and best-effort fsyncs the parent directory after rename.  A mid-write crash leaves no snapshot at the final path (safe) rather than a rename'd-but-unflushed file that reads as truncated on recovery.
- **F-30-2 log-structured semantics commitment (docstring):** `snapshot.rs` `# Snapshot semantics` section commits the design to log-structured checkpointing: snapshot bytes ARE a canonical `Vec<WalEntry>` encoding.  Late-join replay is the concatenation of all snapshots from genesis forward.  A future slice may add a materialized-state variant for faster join.
- **F-30-5 retention:** new `prune_snapshot_dir(dir, keep_last_n)` — mtime-based prune.  Called after each successful `SnapshotWriter::maybe_write`.  Bounded disk usage by `retain * snapshot_size`.
- **H-30-2 return-plumbing:** `play_deploy_with_cost_accounting` now returns `(ProcessedDeploy, NumberChannelsEndVal, Vec<WalEntry>)`.  `play_deploys_for_state` aggregates the per-deploy `Vec<WalEntry>` into a per-block slice, computes the WAL root, and logs it at INFO level.  Pre-fix, `EvalCollector.fs_wal_entries` was silently dropped on function return.
- **Snapshot cadence loop:** new `SnapshotWriter { dir, cadence, retain }` in `snapshot.rs` with `maybe_write(block_number, entries) -> Result<Option<[u8; 32]>>`.  Writes on blocks where `block_number % cadence == 0`, prunes to `retain` afterward.  Attached to `RhoRuntimeImpl.fs_snapshot_writer: Option<SnapshotWriter>` via new `set_fs_snapshot_writer` setter.  `play_deploys_for_state` calls `maybe_write` at the end of each block if the writer is set.
- **RuntimeManager plumbing:** `RuntimeManager.fs_snapshot_writer: Arc<RwLock<Option<SnapshotWriter>>>` (Clone-shared).  `set_fs_snapshot_writer(w)` installs it once at boot; `spawn_runtime` / `spawn_replay_runtime` attach the current value to every spawned runtime.  Boot integration is a single call.
- **H-30-1 boot builder:** new `snapshot_config::build_snapshot_writer(provisioning, cadence, dir) -> Result<Option<SnapshotWriter>>` combines validation with construction; retention derived as `retain = max(2, cadence * 2)`.  Boot pipeline calls this once, then `runtime_manager.set_fs_snapshot_writer(writer)` — deferred to slice 30c (the actual node-startup integration lives in a different code path).

**Deferred to slice 30c (deliberate):**
- Top-level boot call to `build_snapshot_writer` + `set_fs_snapshot_writer` (H-30-1 remaining wiring — bounded plumbing task in node startup).
- ProcessedDeploy proto extension for on-chain WAL Merkle root commitment (hard fork — needs coordinated network upgrade).
- Joining-validator snapshot-fetch protocol (new network protocol — needs cross-team design).
- H-R3 Par-parallel WAL ordering determinism (needs Rholang runtime scheduler change; blocks on-chain commitment).
- M-29-3 partial-write correctness (record actual `n` bytes — requires follower to parse `n` from `previous` cache).
- H-R2 hard-checkpoint WAL snapshot (no `revert_to_hard_checkpoint` exists yet; if one is added, must snapshot WAL too).
- F-30-8 system-deploy WAL attribution (close-block etc. currently unattributed).

**Slice 30b test coverage:** rholang io::snapshot 25/25 (was 17; added 3 prune tests + 5 SnapshotWriter cadence/retention tests + fsync-through-writer coverage via the writer tests).  node snapshot_config 21/21 + 1 ignored (was 17 + 1; added 4 `build_snapshot_writer` tests).  All slice-29/30 regression tests still green (rholang io lib 83/83, fs_wal_spec 14/14, file_dir_check 435/435, casper lib 286/286).  Fmt + clippy clean.



**Round-2 review fixes (2026-08-05):** three-agent security / FIPS / test-coverage review surfaced 2 Criticals plus 7 Highs plus 3 Mediums.  Fixes:

- **C-30-1 (Critical): `?`-early-return WAL leak.**  Pre-fix, five `?` operators in `play_deploy_with_cost_accounting` could early-return between `begin_deploy` and the two drain sites, leaving WAL entries in the per-runtime buffer that poisoned the next deploy's slice.  Fix: new `WalDeployScope` RAII guard (`casper/src/rust/rholang/runtime.rs`) captures the mark on construction and drain-discards on Drop unless `take_and_commit` was called.  Success + pre-charge-failure Ok paths call `take_and_commit`; every `?`-error path is now safely covered by Drop.  Pinned by 5 new unit tests: `wal_deploy_scope_take_and_commit_returns_entries_and_empties_wal`, `wal_deploy_scope_drop_without_commit_discards_entries`, `wal_deploy_scope_early_return_pattern_does_not_leak`, `wal_deploy_scope_sequential_deploys_are_isolated`, `wal_deploy_scope_failed_deploy_does_not_pollute_next_deploy`.
- **C-30-2 (Critical): drain wiring had zero test coverage; plan's coverage claim was false.**  The plan asserted round-2's `wal_is_byte_identical_on_leader_and_follower` covered the drain; it does not (that test goes through `RhoRuntime::evaluate` + `create_checkpoint`, not `play_deploy_with_cost_accounting`).  Fix: the 5 `WalDeployScope` unit tests above provide targeted coverage — a regression removing every drain call now fails 4 of them.  Full-integration coverage of the play-deploy path is deferred to slice 30b (requires proto changes to plumb fs_wal_entries into `ProcessedDeploy`).
- **H-30-1 (High): validate_snapshot_config not wired into boot.**  Ignored placeholder test `boot_pipeline_calls_validate_snapshot_config` panics with H-30-1 message when run under `--ignored` — jumps out at code review and CI when slice 30b needs to wire the boot integration.
- **H-30-3 (High): platform-dependent path encoding.**  Documented in the `snapshot.rs` module-level docstring (`# Platform scope`) that the FIP scopes to Unix and that a future Windows port needs to encode logical bucket keys instead of host `PathBuf` bytes.  Not a bug today given the FIP's Unix-only scope, but the docstring makes the invariant explicit for future maintainers.
- **H-30-4 (High): no golden-value encoding test.**  Added `compute_wal_root_golden_hex` — pins `06a8ce93...b825` for a canonical single-entry slice.  Any silent encoding change (Blake2b256 config, prefix width, endianness, `PathBuf::as_encoded_bytes()` semantics) trips this test.
- **H-30-5 (High): `op_tags_are_stable` doesn't prove `encode_entry` uses the tags.**  Added `encode_entry_uses_op_tag_values` — encodes one entry per WalOp variant and asserts the first byte of the entry region matches the expected tag.  Catches a refactor that inlines `e.op as u8` (auto-discriminants).
- **H-30-6 (High): WAL-root debug log format not asserted.**  Log format is stable (field names `deploy_sig`, `n_entries`, `wal_root` unchanged); explicit test would require capturing the tracing subscriber which is heavy for one field.  Accepted as low-value; documented as slice 30b concern.
- **H-30-7 (High): DeployRef byte-layout stability not pinned.**  Added `deploy_ref_encoding_is_big_endian_and_field_order_is_stable` — verifies tag byte, block_hash-first ordering, big-endian `deploy_index` / `arg_index`, and that swapping the two indices produces different roots.
- **M-30-1 (Medium): deterministic `.wal.tmp` filename causes in-process concurrent-writer race.**  Fix: tmp filename now includes PID + nanoseconds (`{stem}.{pid}-{nanos}.wal.tmp`), so two threads writing the same content-addressed snapshot no longer stomp the same tmp path.  POSIX rename is atomic; identical content means either winning tmp file becomes the identical final `.wal` file.
- **M-30-2 (Medium): snapshot_dir never canonicalized.**  `validate_snapshot_config` return type changed from `Result<()>` to `Result<Option<PathBuf>>` — on success returns the canonicalized absolute path (with symlinks resolved).  Pinned by `valid_config_returns_symlink_resolved_dir`.
- **M-30-3 (Medium): probe file symlink race.**  Fix: `probe_dir_writable` now uses `OpenOptions::new().write(true).create_new(true)` (O_EXCL semantics) so a pre-existing file / symlink at the probe path fails hard with `AlreadyExists` instead of truncating the target.  Pinned by `o_excl_semantics_reject_existing_file` and `probe_uses_o_excl_and_cleans_up`.
- **Coverage additions:** `every_walop_variant_encodes_distinctly` (all 9 op variants round-trip), `every_option_some_arm_encodes_distinctly_from_none` (extra_path / mode_bits / owner / group Some-arms; empty-vs-None distinguishability), `read_snapshot_nonexistent_file_returns_io_error`, `probe_dir_writable_fails_on_read_only_dir` (Unix-only, permission-manipulating).

**Deferred to slice 30b (explicit in plan):**
- **H-30-2:** `fs_wal_entries` is populated on `EvalCollector` but dropped on function return (not part of the return tuple).  Plumbing it out requires a `ProcessedDeploy` proto extension = hard fork.
- **F-30-2 (FIPS Medium):** snapshot bytes are a *WAL slice*, not a materialized fs image.  Either commit to log-structured semantics or add a materialized snapshot in 30b.
- **F-30-5 (FIPS Medium):** no retention/cleanup policy.  Content-addressed filenames prevent collision, but disk fills without cleanup.
- **F-30-7 (FIPS Medium) / H-R3 (slice 29 round-2):** Par-parallel WAL ordering non-determinism unresolved.  Blocks 30b's on-chain commitment.
- **F-30-8 (FIPS Low):** system-deploy WAL attribution unspecified.
- **F-30-12 (FIPS Low):** no fsync before rename.

**Round-2 test coverage delta:** rholang io::snapshot 17/17 (was 11; added `compute_wal_root_golden_hex`, `encode_entry_uses_op_tag_values`, `deploy_ref_encoding_is_big_endian_and_field_order_is_stable`, `every_walop_variant_encodes_distinctly`, `every_option_some_arm_encodes_distinctly_from_none`, `read_snapshot_nonexistent_file_returns_io_error`).  node snapshot_config 17/17 + 1 ignored (was 13; added `valid_config_returns_symlink_resolved_dir`, `probe_uses_o_excl_and_cleans_up`, `o_excl_semantics_reject_existing_file`, `probe_dir_writable_fails_on_read_only_dir`, `boot_pipeline_calls_validate_snapshot_config` [ignored H-30-1 placeholder]).  casper lib rholang::runtime 10/10 (was 5; added the 5 WalDeployScope tests above).  All slice-29 regression tests still green (rholang io lib 69/69, fs_wal_spec 14/14, file_dir_check 435/435, casper lib 286/286).

**MVP deliverables:**
- **Per-deploy WAL scoping wired into `play_deploy_with_cost_accounting`** (`casper/src/rust/rholang/runtime.rs`): the deploy boundary is marked at the top via `Wal::begin_deploy()`; entries are drained via `Wal::take_deploy_entries(mark)` on both the success path (post-refund `Ok`) and the pre-charge-failure path (empty_pd `Ok`).  Drained entries are attached to a new `EvalCollector.fs_wal_entries: Vec<WalEntry>` field for slice 30b to hook on-chain.  Per-deploy WAL root is computed via `compute_wal_root` and logged at `tracing::debug` level with the deploy signature + first 8 bytes of the root for operator observability.  Ensures deploy-N's WAL entries do not leak into deploy-N+1's slice.
- **Snapshot module** (`rholang/src/rust/interpreter/io/snapshot.rs`): canonical byte encoding of `Vec<WalEntry>` (prefix-length + big-endian, no protobuf/serde — the encoding IS the consensus commitment) + `compute_wal_root` (Blake2b256 of canonical bytes) + `write_snapshot` / `read_snapshot_bytes` (content-addressed on-disk storage under `{dir}/{root_hex}.wal` with tmp+rename atomicity + read-time root verification).  Encoding schema explicitly documented as hard-fork-guarded; `op_tag` values are pinned by a unit test so an enum-order shuffle cannot silently change the WAL root.  New `PayloadRef::DeployRef` branch has its own tag byte distinct from `Hash`.
- **Snapshot config keys** (`node/src/rust/configuration/model.rs`): `storage.consensus-fs-snapshot-cadence: Option<u64>` and `storage.consensus-fs-snapshot-dir: Option<PathBuf>`.  Both `Option` at the parse layer with `#[serde(default)]` so existing configs load unchanged.
- **Boot-time validation** (`node/src/rust/configuration/snapshot_config.rs`): new `validate_snapshot_config(provisioning, cadence, dir)` — if any `consensus-static-*` bucket is provisioned, both keys are required (`SnapshotConfigError::MissingCadence` / `MissingDir` with diagnostic pointing at the FIP §Q-6 trade-off), `cadence >= 1` (zero rejected explicitly to guard against divide-by-zero at cadence-check time), and the dir must be writable (touch-and-remove probe with random-ish tmp filename to avoid parallel collisions).  Backward-compat: nodes with no consensus-static buckets skip validation entirely.

**Slice 29 round-2 leftover deferrals reassessed:**
- **H-R2** (hard-checkpoint WAL snapshot): no `revert_to_hard_checkpoint` exists yet; the constraint is documented but no code fix needed until a future slice introduces one.  Still slice 30b.
- **H-R3** (Par-parallel WAL ordering): unchanged.  The snapshot encoding orders entries by their insertion order into `Wal::entries`; if Rholang's Par scheduling under Tokio is non-deterministic, the WAL root diverges even between two replays on the SAME validator.  Slice 30b will decide the resolution (serialize Consensus writes via a runtime-wide semaphore, or make Rholang small-step scheduling deterministic).  For the MVP, single-validator replay under the current is_replay short-circuit is sufficient because the follower re-plays the leader's cached `previous` in the same order.
- **M-29-3** (partial-write correctness): unchanged; still recording REQUESTED bytes.  A follow-up slice will restructure so both sides record actual `n` from `previous`.
- **ProcessedDeploy proto extension** (hard fork): unchanged; slice 30b bundles this with the on-chain WAL Merkle root commitment field.

**Deferred to slice 30b:**
- Snapshot cadence loop wired into block processing (write snapshot every N blocks).
- Joining-validator fetch protocol (request snapshot by root, verify byte-for-byte).
- WAL replay engine (apply canonical-encoded entries against a base image).
- ProcessedDeploy proto extension for on-chain WAL entry attachment (hard fork).
- Wire `snapshot_config::validate_snapshot_config` into the actual boot pipeline (currently a standalone helper; boot integration mirrors slice 24's `merge_and_validate` pattern).

**Tests (24 new, 0 regressions):**
- `rholang/src/rust/interpreter/io/snapshot.rs` unit tests (11): empty slice encoding + determinism, same/different-entries root discrimination (order, payload, path), snapshot disk round-trip, tamper rejection, write idempotence, op-tag stability pin, DeployRef-vs-Hash distinction.
- `node/src/rust/configuration/snapshot_config.rs` unit tests (13): no-consensus-provisioning skips validation, missing-cadence with files / dirs fails distinctly, zero-cadence rejected, missing-dir with valid cadence fails, valid tempdir passes, creates dir if missing, unwritable dir (path-is-a-file) fails, `requires_snapshot_config` truth table for empty/consensus-files/consensus-dirs/oracle-only.
- Per-deploy drain integration coverage: the round-2 `wal_is_byte_identical_on_leader_and_follower` test (fs_wal_spec) already exercises `play_deploy_with_cost_accounting`'s drain (via `create_checkpoint` after evaluate, which flushes the runtime).  A future slice-30 integration test can additionally verify per-deploy attribution once the on-chain field lands.

**Green results:** rholang io lib 69/69 (including 11 new snapshot); rholang fs_wal_spec 14/14; rholang file_dir_check 435/435; node lib 310/310 (including 13 new snapshot_config); casper lib 281/281; casper mod 829/830 (only the pre-existing merge-algebra Finding-A bug from `docs/theory/merge-algebra/merge-algebra-verification.md §6` remains — out of scope for slice 29/30/31).  Fmt + clippy clean.

**Pre-MVP plan text preserved below:** configurable-cadence content-addressed snapshots; joining-node fetch + WAL replay.  **2026-08-03:** boot validation for the `storage.consensus-fs-snapshot-cadence` config key — no default; missing value must fail boot with a clear diagnostic.

**Effort**: 3–4 days for slices 21-26 (config surface + CLI + tree walk + merge + bundle handoff + `ConsensusMode` routing).  Slices 28-30 (crash-recovery re-close, consensus-mode WAL, consensus-mode snapshots) are a larger addition — estimated 5-7 days on top; may split into a Phase 7a (crash recovery, small) and Phase 7b (consensus filesystem replication, larger).  See 2026-07-30 note in `powerbox-requirements.md` revision log.

### Phase 8 — Concurrency: range locks + wait-vs-fail + line-vs-byte coordination

**Scope**: the interval-tree range-lock implementation + the `{"wait": true}` option wiring.

**Deliverables**:

- Range-lock interval tree per `File` agent, held in `*this`-keyed private state.
- **Interval-tree location: Rust-side, in the `File`-agent's `SystemProcesses` state, not Rholang.**  Reasoning: a Rholang interval tree would need `<=`/`<` comparison operators via native primitives anyway, and every lock-acquire/release would be O(log n) Rholang message dispatch — expensive per positional call.  Native-side lets the tree be a `std::collections::BTreeMap<u64, LockRange>` behind an `Arc<Mutex<...>>` on `ProcessContext`, with acquire/release as native syscalls exposed at `rho:io:fs:native:1.0.0/{lockRange,releaseLock}`.  The library agent's `File.lockRange` method wraps the native and returns a `LockToken` (a Rholang agent that holds the returned lock-id and invokes `releaseLock` on `!release()`).
- Implicit locks on positional methods (`bytesAt`, `writeBytesAt`, buffer-taking positional variants).
- Explicit `lockRange(offset, length, mode) → [true, lockToken]`; `lockToken!release()`.  Lock tokens are `bundle+`; the forwarder pattern is the tool for hand-out-without-release.
- `{"wait": true}` option: blocks (via message-arrival semantics) until the lock is acquired instead of returning `"FSERR_BUSY"`.
- Sequential-stream single-active enforcement via a boolean flag on `File`'s metadata; sequential streams take the whole-file lock in the interval tree.
- Race-window enforcement: File-agent dispatch loop serializes stream-constructing calls (already the case for `agent` blocks; documented explicitly).
- **Augment Phase 5's placeholder sequential-stream conflict behavior**: Phase 5 delivered "second call returns `FSERR_BUSY` immediately"; this phase adds the `{"wait": true}` option that blocks and eventually acquires when the first stream is closed / the range lock released.

**Design constraints**:

- Line-vs-byte invariant follows as a corollary of "sequential holds the whole-file lock" (no separate named mutex).
- `writeBytesAt` takes explicit `maxLength` so the write lock's extent is known at acquisition (not pessimistic-to-EOF).
- Dropped `lockToken` leaks the lock until deploy end; document in §Concurrency; implementations MAY auto-release on deploy-end.
- Lock mode subject to File mode attenuation: `lockRange(_, _, "w")` on a `"r"` File → `"FSERR_UNSUPPORTED"`.

**Tests**:

- Two concurrent `bytesAt` on disjoint ranges → both succeed.
- Reader + writer on overlapping ranges → second gets `"FSERR_BUSY"`.
- Sequential stream + positional call → second gets `"FSERR_BUSY"`.
- `{"wait": true}` blocks then acquires when the holder releases.
- Explicit `lockRange` held across multiple positional calls, then `release`.
- File-agent dispatch: two concurrent stream-constructor calls dispatched serially, deterministic outcomes.

**Effort**: 4–5 days.

### Phase 9 — Cost accounting scaffolding

**Scope**: wire consensus-critical per-native cost accounting through whatever charging surface the interpreter presents.  Under D3 (`feature/cost-accounted-rho`) this is `BillableTokenEvent::Primitive` descriptors committed via `RuntimeBudget::reserve_canonical_with_cost`; pre-D3 it's `CostManager::charge()` at handler entry.  Same design intent; different mechanism.  See X-4 supplement below for the D3 migration story.

**Deliverables**:

- **Per-native cost emission at handler entry.**  Each native handler emits one `BillableTokenEvent::Primitive` with a deterministic weight (or, pre-D3, calls `CostManager::charge()` with the same numeric weight).  Weights consensus-critical from day one under D3 — a change is a hard-fork.
  - `open`/`close`/`stat`/`exists`/`chmod`/`chown`/`seek`/`tell`/`size`/`truncate`/`flush`/`quarantine`/`lockRange`/`lockSequential`/`releaseLock`: constant ~100 (calibrated against `equality_check_cost`; matches the fs_open class).
  - `read`/`readAt`: `c_open + bytes_read`.
  - `write`/`writeAt`: `c_open + 2 * bytes_written`.
  - `entries`: `50 + 32 * n_entries`.
  - `rename`/`copyFile`/`removeFile`: constant ~200.
  - `removeDir` recursive: `200 + per-entry cost across the tree`.
  - UTF-8 primitives: proportional to byte length.
  - `concatBytes`: linear in total byte length.
- **Per-stream-method cost** (Rholang library layer): per-element / per-chunk / per-byte transferred.  Under D3 these are NOT explicit `charge` calls — the recursive metering kernel authorizes source-token consumption at every rule-1..5 boundary; library-agent method dispatch is not a separate metering surface.  Pre-D3 they were explicit `CostManager::charge()` calls.
- **Per-buffer-method cost** per §Cost accounting > Buffers.  Under D3, per-instance dispatcher cost is the recursive-metering cost at agent-block instantiation, not `storage_cost_consume`.
- **Materialization caps** as stopgap defense-in-depth (unchanged by D3): `toString(cap)`, `toByteArray(cap)`, `toList(cap)` with a `FSERR_QUOTA_EXCEEDED` reply above the cap.
- **Reply-payload cap** on `EntryStream.chunk(n)` (records) and `ByteStream.chunk(n)` (bytes) to bound reply payload size.  (`LineStream` doesn't support `chunk` at all per spec §chunk method, so no cap needed there.)

**Design constraints**:

- **Under D3**: weights are consensus-critical from day one — every validator must agree.  Weight change = hard fork.  Coordinate activation with the eventual cost-accounted-rho merge's hard-fork block-height trigger (`docs/theory/cost-accounting-migration.md` §6 step 22).
- **Pre-D3**: constants are additive to existing accounting; no repricing of prior operations.  Full calibration is the follow-up Cost FIP.
- **Migration posture**: implement the D3 weights first (they're stricter — hard-fork discipline).  Pre-D3 fallback uses the same numbers but goes through `CostManager::charge()`.  Same weights, two dispatch paths.

**Deferred to Cost FIP**:

- `readInto` vs. `read` cost decomposition (documented in spec §Cost accounting > Buffers).  Under D3 the `storage_cost_produce` refund path is retired; `readInto` cost becomes the sum of the native `read` event weight and the byte-throughput weight of the `writeBytes` calls that follow, with no refund to reason about.  Document both in the Cost FIP so callers can predict per-fill cost.
- Full weight calibration.

**Tests**:

- Cost regression: sample workloads (open + read + close) with expected phlogiston consumption within tolerance.
- **Buffer read cost — pairwise-merge growth.**  Measure read cost at `ν = 8`, `ν = 64`, `ν = 512` with the buffer library's balanced pairwise merge; assert the growth follows `Θ(ℓ log ν)`, NOT `Θ(ℓ ν)`.  A `ν = 1` test cannot catch a fold-vs-merge regression (nothing to merge at ν=1), so this is the actual regression guard: a future well-meaning refactor to `List.fold(concatBytes)` would silently quadruple cost between `ν = 64` and `ν = 512`, and this test would catch it.
- **Weight-drift pin**: golden-value test asserting each native's weight constant — matches the slice-34 pattern for consensus-committed constants.  Under D3, drift here is a hard-fork.

**Effort**: 2–3 days pre-D3.  Under D3 the port through `BillableTokenEvent::Primitive` is roughly the same effort — the emission call site pattern is uniform.

**D3-migration reference**: X-4 supplement below has the reframing rationale.  When the cost-accounted-rho merge lands, the three inline references to `CostManager::charge()` (Phase 1 §51, §Reference points, §Buffer library size on-chain) should be updated to name both mechanisms.

### Phase 10 — Ocap examples + end-to-end tests

**Scope**: canonical example `.rho` scripts + comprehensive integration tests.

**Deliverables**:

- `examples/fileio_static.rho` — static-config path: open a file, read via `lines()`, write via `writeLines`, roundtrip assertion.
- `examples/fileio_buffer_loop.rho` — bounded memory read of a large file via a preallocated buffer + `readLineInto` loop.
- `examples/fileio_stdio.rho` — echo stdin to stdout with `readLine`/`writeString`.
- `examples/fileio_membrane.rho` — file agent behind a revocable membrane; revoke → `"FSERR_REVOKED"`.
- `examples/fileio_readonly_forwarder.rho` — read-only forwarder using the §Ocap patterns > Attenuation via forwarder template.
- `examples/fileio_parallel.rho` — `foldConcurrent(sum, 8)` over a byte stream, verify convergence.
- `examples/fileio_chown_consensus.rho` — verify `chown` in consensus mode returns `"FSERR_UNSUPPORTED"`.
- `examples/fileio_rows.rho` — buffer-of-buffers via `allocator!allocRows(128, 8192, "utf8")` + `file!readLinesInto(rows)`; iterate rows and print.
- `examples/fileio_cross_fs_isolation.rho` — construct two `Fs` instances via the stub Powerbox with distinct `deployerId`s; verify Alice's membrane around a `File` is invisible to Bob when Bob opens by the same logical name (mirrors the Phase 6 test but as a runnable example).
- `examples/fileio_lockrange.rho` — explicit `lockRange` held across multiple positional calls, released deterministically via a scoped `try @token <- ... { ... token!release() }` pattern.
- Per-error-code integration test: provoke each `"FSERR_*"` / `"BUFERR_*"` / `"EOS"`, verify the catch arm fires with the right code.
- Replay end-to-end: run each example under the oracular replay harness; verify follower `ProcessedDeploy` matches lead's.

**Effort**: 3–4 days.

## Test infrastructure

Three layers mirroring the existing casper conventions:

1. **Unit tests** on native primitives, in `#[cfg(test)]` blocks alongside each handler.  Fast; run under `cargo test -p rholang --lib io::`.
2. **Runtime integration tests** at `rholang/tests/fileio_*.rs`, driving `RhoRuntimeImpl` end-to-end.  Established patterns:
   - `fileio_native_spec.rs` — per-native positive + error paths.
   - `fileio_replay_spec.rs` — oracular play/mutate-disk/replay harness; assert `check_replay_data` succeeds.
   - `fileio_consensus_replay_spec.rs` — consensus-mode: run under `ConsensusMode::Consensus`, capture the leader's `stat`/`entries` reply, replay on a follower, assert byte-identical (host-transient fields omitted from both sides).  Regression guard for the field-omission plumbing.
   - `fileio_lifecycle_spec.rs` — fd-table sharing + commit/rollback invariants around the production deploy path.
   - `fileio_buffer_spec.rs` — buffer library end-to-end (allocation, write/read/reuse, lease, revocation, monotonic-index invariant).
   - `fileio_stream_spec.rs` — stream library end-to-end (all combinators, all specializations, `LineStream.chunk`/`foldChunks`/`foldConcurrent`/`mapReduce` all → `"FSERR_UNSUPPORTED"`).
   - `fileio_file_spec.rs` — File agent end-to-end (all methods, concurrency, buffer-taking variants, `default`-arm coverage).
   - `fileio_dir_spec.rs` — Dir agent end-to-end (all methods, quarantine, attenuation, `default`-arm coverage).
   - `fileio_fs_spec.rs` — Fs top-level (static config → openFile → File methods; stdio; `default`-arm on Fs/Stdin/Stdout; cross-`Fs` ocap-isolation).
   - `fileio_cost_spec.rs` — dedicated cost-regression suite hosting all Big-Θ assertions (buffer read growth at `ν = 8/64/512`, `readInto` vs `read` cost split, per-native constant sanity checks).
3. **Oracular replay in CI** — for each example, run once as lead capturing non-deterministic events, replay as follower, assert `ProcessedDeploy` trees match.  Wired into the existing casper test infrastructure.

## Rough effort estimate

| Phase | Effort | Notes |
|---|---|---|
| 0 — Prerequisites (verify) | | Ongoing background |
| 1 — Native filesystem primitives (22 syscalls incl. `entriesStream`) + consensus-mode enum threading | 5–6 days | Foundation; blocks everything else |
| 2 — UTF-8 + `concatBytes` primitives | 1–2 days | Small; can parallel with Phase 1 tail |
| 3 — Buffer library + allocator | 7–10 days | Most intricate Rholang code (first agent-library authored under the new spec) |
| 4 — Stream library | 4–5 days | Depends on Phase 2 conceptually (chunk-container types) but not on `concatBytes` directly; parallel with Phase 3 |
| 5 — File + Dir agent library | 8–11 days | Big surface area (~40 methods); depends on 3 and 4; concurrency behavior split with Phase 8 |
| 6 — `Fs` agent + stdio + genesis + stub Powerbox | 4–5 days | Depends on 5; per-`deployerId` Powerbox stub included |
| 7 — Static provisioning + CLI | 3–4 days | Coding parallel with 3-5; acceptance testing Phase-6-gated |
| 8 — Concurrency (range locks + wait, augments Phase 5) | 4–5 days | Depends on 5; Rust-side interval tree |
| 9 — Cost accounting scaffolding | 2–3 days | Depends on 1-8 |
| 10 — Ocap examples + E2E tests | 3–4 days | Depends on 6-9 |
| **Total (sequential)** | **~42–55 days** | ~8-11 weeks of focused work |
| **With parallelism (2 people)** | **~6-8 weeks** | Phases 3+4 in parallel; Phase 7 coding parallel with 3-5; critical path is 1→2→3→5→8→6→9→10 ≈ 40 days |

## Sequencing and dependencies

```
Phase 0 (verify prerequisites)
  ↓
Phase 1 (native FS) ═══════════════════════════
  ↓                                            ║
Phase 2 (UTF-8 + concatBytes)                  ║
  ↓                                            ║
  ├─────────────┐                              ║
  ↓             ↓                              ║
Phase 3 (Buffer)  Phase 4 (Stream)  Phase 7 (config/CLI, coding-only)
      ↓            ↓                           ║
      └──────┬─────┘                           ║
             ↓                                 ║
       Phase 5 (File + Dir)                    ║
             ↓                                 ║
       Phase 8 (Concurrency)                   ║
             ↓                                 ║
       Phase 6 (Fs + stdio + genesis) ←════════╝
             ↓
       Phase 9 (Cost)
             ↓
       Phase 10 (E2E + examples)
```

Phases 3, 4, and 7 (coding-only) can run in parallel on the same tier if two implementers are available.  **Phase 7's acceptance testing is Phase-6-gated** (the config bundle needs a working `Fs` to hand it to), so Phase 7 can be coded ahead but its integration tests wait for Phase 6.  Phase 2 must precede Phase 3 (the buffer library's chunk-gather calls `concatBytes`).

## Risks and open questions

**Powerbox stub.**  The Powerbox FIP is in draft.  For the interim, the genesis deploy publishes a stub Powerbox that mints one `Fs` (and one allocator) instance **per authenticated `deployerId`** — extracted from the `NormalizerEnv`'s `rho:deploy:data` + `rho:system:deployerId:ops` bindings, the same shape the Versioned Registry uses.  This keeps the URN semantics stable across the Powerbox transition: `getFs(`rho:io:fs:1.0.0`)` returns a per-principal handle from day one, and Alice's membrane around a `File` is not bypassable by Bob because Bob's `Fs` mints distinct `File` instances backed by distinct fds.  When the real Powerbox FIP lands, only the delegation policy inside the stub is replaced — the client-side lookup shape is unchanged.  Boot log records which deploys received which cap; documented in the Fs section's usage prose.

**Range-lock deadlock detection.**  The FIP explicitly punts on this ("no deadlock detection; documented `FSERR_BUSY` under contention").  Callers who need cross-file atomicity build their own protocol.  Deadlock avoidance (ordered lock acquisition) is application-level.  Nothing to do at the implementation layer beyond documenting.

**Consensus-mode field filtering.**  The spec says `stat`/`entries` records **omit** `mtime`/`ctime`/`atime`/`owner`/`group` in consensus mode (not zero them).  Because Rholang Map matching supports absent keys via `.get(k)` → `Nil`, this is a natural fit — but the native has to know which mode it's running under.  Implementation: pass the mode into `SystemProcesses` at construction (from `ProcessContext`), branch inside `stat.rs::stat_record`.

**NSS transient failures.**  `resolve_uid` / `resolve_gid` must distinguish transient failure (`Err → "FSERR_IO"`) from not-found (`None → omit field or "FSERR_BAD_ARG"` for `chown`).  Otherwise an LDAP outage looks like a bad username.  Concretely: check `rc != 0 && rc != ENOENT` separately from `rc == 0 && result.is_null()`.

**Buffer library size on-chain.**  `Buffer.rho` + `Rows.rho` + allocator will be roughly 300-500 lines of Rholang plus a hex-digit lookup map.  The genesis deploy's phlogiston cost is a one-time charge, but the persistent-dispatcher storage cost per instance is per-runtime and never refunded (Agents desugaring installs one persistent receive per instance).  Callers that churn many buffers must `close()` explicitly to refund byte storage; the persistent dispatcher waits for deploy-end GC.

**Parallel-combinator scheduling determinism.**  `foldConcurrent`/`mapReduce` require `combine`/`reduceFn` to be commutative and associative for a well-defined result independent of scheduling.  Under multi-node replay the lead's scheduling is captured and replayed to followers, so consensus is deterministic even if the callback isn't strictly commutative — but local dev runs may vary.  Document this clearly on both methods' spec sections and in cost-regression tests.

**Chunk-count reply-size cap.**  `Stream.chunk(n)` on a `ByteStream` returning `n` bytes at $`n = 64 MiB`$ produces a single `ByteArray`; on an `EntryStream` returning `n` records with 9-key maps, roughly 100+ bytes per record, so the reply is proportional to $`n \cdot 100+`$ bytes.  The base `chunk` needs its own cap on `EntryStream` (records) and `ByteStream` (bytes) — independent of the underlying source cap — so a caller who asks for a million entries doesn't blow reply-payload memory.  `LineStream.chunk` returns `"FSERR_UNSUPPORTED"` per the spec, so no cap needed there.  §Buffers > Cost accounting suggests $`\ge 1024`$ as the guaranteed minimum.

## Reference points in the current codebase

- **System processes**: `rholang/src/rust/interpreter/system_processes.rs` — shape of `Definition` rows, `FixedChannels`, `BodyRefs`, `non_deterministic_ops()`.  Copy the shape of `verify_signature_contract` for handler layout.
- **Reduce methods**: `rholang/src/rust/interpreter/reduce.rs` — where UTF-8 primitives land in the method table (see `to_utf8_bytes_method` for the pattern).
- **Cost accounting**: `rholang/src/rust/interpreter/accounting/costs.rs` — per-op cost functions; `accounting/mod.rs:43-69` for the `charge()` primitive.
- **Non-deterministic replay**: `rholang/src/rust/interpreter/dispatch.rs` — `FailedNonDeterministicCall` path; the `is_replay` guard pattern.
- **URN registration**: `rholang/src/rust/interpreter/rho_runtime.rs` — `std_system_processes()` builds the URN → handler mapping; `is_internal_urn` filters user-reachable URNs.
- **Standard-library Rholang**: `casper/src/main/resources/` — `NonNegativeNumber.rho`, `Stack.rho` are the two agent-block precedents to copy the structure from.
- **Genesis deploy wiring**: `casper/src/rust/casper/rho_names.rs` or equivalent — the table binding logical names to `rho:id:*` hashes; `StandardDeploys.rs` for the deploy sequence.
- **Test scaffolding**: `casper/tests/util/rholang/runtime_manager_test.rs:49-74` for the standard "deploy a `.rho` and verify replies" harness.
- **CLI**: `node/` binary crate for the config-loader + CLI-flag parser (Phase 7).

## Phase 8 design direction — range-lock architecture (X-1 resolution)

Recorded 2026-08-06 following Phase 7 whole-review's X-1 cross-phase tension.  Slice 27's fresh-mint (one kernel fd per cap; two `Fs.openFile(same-name)` calls yield distinct caps with independent cursors) was the correct Phase 7 decision, but it means Phase 8's range-lock protocol needs shared state that **cuts across cap boundaries** — otherwise Alice's `bytesAt(0, 1024)` on one cap wouldn't conflict with Bob's overlapping `writeBytesAt(500, 1024)` on a fresh cap of the same file, defeating the "cross-cap coordination via the range-lock protocol on the underlying path" guarantee in §Race-window notes.

Agreed Phase 8 requirements:

1. **Per-path lock table** — separate from `FileHandleTable`; keyed on `(dev, inode)`.  Inode-keying naturally handles symlinks, bind mounts, and hard-linked aliases without an eager `canonicalize`-on-lock-acquire syscall.  **Separate struct (`LockRegistry`), not an extension of `RootIdentityRegistry`** (2026-08-11 refinement): the two data structures are structurally disjoint — `RootIdentityRegistry` is keyed on `PathBuf` (roots only), holds `(dev, inode)` values, populated once at boot, never evicted; `LockRegistry` is keyed on `(dev, inode)` (any leaf file), holds `FileLockState` values, populated per-acquire, evicted on last-release / last-cap-close.  Merging into one struct either forces two logically-disjoint sub-maps behind one name or an `enum` value every reader has to match on.  Instead: colocated on `RuntimeManager` and broadcast via the same `share_*` pattern; sharing is at the identity-helper layer (`fstat_dev_inode`, `capture_root_identity`), not the struct layer.  Lexical-canon `PathBuf` keying is available as a fallback only if the identity table isn't yet plumbed into the syscall path where locks acquire.

2. **Lock acquisition** — separate from OS fd open.  Because fresh-mint means the OS fd is per-cap and short-lived, we can't piggyback on `fcntl(F_OFD_SETLK)` (locks would vanish when the last fd closed).  Instead, the lock lives in the per-runtime (or per-manager) lock table and is checked at each byte-level syscall's dispatch time.

3. **Lifecycle coupling** — Alice's lock survives across deploys per §Explicit locks ("Held until `release`").  Auto-release at deploy-end is MUST (2026-08-11 commitment; spec §Explicit locks amended from MAY to MUST for cross-validator determinism — a MAY leak would diverge the lock table across validators that make different MAY choices).  The `WalDeployScope` machinery (H-2 fix, casper/rholang/runtime.rs) is the natural place to hang the mandatory deploy-end sweep: on `WalDeployScope::end` (or equivalent), invoke `LockRegistry::release_all_for_deploy(scope)`.  The row shape falls out of the four operations `LockRegistry` must serve: `try_acquire(range, mode, holder)`, `release(range, holder)`, `release_all_for_holder(holder)` (cap-close cleanup), `release_all_for_deploy(scope)` (deploy-end cleanup), and `is_locked(range)` (consensus-mode unlink gate).  Each entry therefore needs the range + mode, plus a holder identity comparable across those operations; concrete types (opaque per-runtime `LockId` handed back inside `LockToken`; whatever key `WalDeployScope` already uses for the deploy tag) are implementation-choice, not design-choice.

4. **WAL journaling — SKIPPED for slice 8a** (2026-08-12 refinement, superseding original mandate for `WalOp::LockAcquire` / `WalOp::LockRelease` variants).

    ~~*Original design*: new `WalOp::LockAcquire { range, mode, outcome: Success | Failure(code) }` + `WalOp::LockRelease { range }` variants; hard-fork bump of `SNAPSHOT_FORMAT_VERSION`; both MVP and Rig-protocol follow-up journal post-decision with the H-6 outcome-variant pattern.~~

    **Refined analysis (2026-08-12).**  Working through the consensus-safety argument in detail after step-3 review revealed that WAL journaling for locks is defensible-but-not-mandatory:
    - Every consensus decision influenced by a lock (step 7's `fs_remove_file` gate; user code branching on `fs_lock_range` reply) reaches the follower via `is_replay = true`, which echoes the leader's captured reply from `ProcessedDeploy.deploy_log`.
    - Follower's `LockRegistry` state is **never consulted for a consensus decision** — every consensus-observable native short-circuits on replay.
    - WAL root consistency: if leader appends `LockAcquire` entries and follower doesn't, roots diverge → fork.  But if NEITHER side journals, both compute the same root over the same non-lock entries.  **Skipping journaling entirely (both sides) is consensus-safe.**
    - Late-joiner state: `LockRegistry` is in-memory and best-effort under oracular (§Mode-differentiated invariants); there's no persistent lock state a joiner needs to reconstitute.

    **Decision**: don't journal lock operations in slice 8a MVP.  Saves the schema extension (`WalOp` variants, `op_tag` values 15/16/17, `encode_entry` match arms), the version bump (3→4), and the golden-hex churn across `wal.rs` + `snapshot.rs` + downstream tests.  Consensus safety comes from `is_replay`-cached replies alone.

    **If future analysis surfaces a case where lock-in-WAL IS load-bearing** — a scenario we haven't spotted where WAL entries provide something the replay log doesn't — we can add lock journaling as a hard-fork amendment.  The `LockRegistry` API is unchanged either way; the change would be internal to the natives.

    **Rig-protocol follow-up (X-2 `wait: true`) unaffected**: the Rig-protocol mechanism captures wait outcomes via synthesized error Produces (spec X-2 follow-up), which flow through the deploy_log the same way as normal outcomes.  Same is_replay short-circuit works.  No WAL role either way.

    **Slice 8a MVP scope reduction**: step 4 removed from the slice 8a step list.  Original steps 5–8 renumbered to 4–7 (File.rho + LockToken, auto-release hook, unlink gate, integration tests).

Placement decision: **`RuntimeManager`-shared Arc<RwLock<...>>**, mirroring the existing sharing pattern (`fs_snapshot_writer` / `pending_wal_slices` / `root_id_registry`).  Rationale: Phase 8 needs same-path locks visible across every runtime spawned from a single node, and the `share_*` broadcast pattern is already the established mechanism.  Alternative "per-runtime table" fails when two runtimes on the same manager attempt overlapping I/O; alternative "OS `fcntl` locks" fails the fresh-mint lifetime constraint.

**Why Rust-side struct and not a Rholang-side lock agent** (design note added 2026-08-07): the Rholang idiom "one message on a channel = mutex" (`for @state <- @lockCh { ... @lockCh!(state') }`) works transiently within a single deploy because RSpace soft-checkpoint reverts on cost exhaustion or panic — the linear receive gets rolled back and the message re-materializes.  Cross-deploy lifetime breaks that protection: Alice's lock in deploy N is meant to survive to deploy N+K, and there's no soft-checkpoint revert that spans deploys.  If the lock state were a Rholang message and any code path between "take" and "put back" failed, the message would be gone AND unreleaseable, and every future acquire would park forever on the empty channel.  A Rust struct with encapsulated `Arc<RwLock<HashMap<CanonId, LockState>>>` closes this by construction: callers can only invoke `try_acquire` / `release` / `release_all_for_deploy` methods, never observe or borrow the raw state, so no client can leave the mutex in a partial-transfer state.  Deploy-end cleanup becomes a first-class method (`release_all_for_deploy(deploy_epoch)`) — mirrors the H-5 `RootIdentityRegistry` pattern.

**Slice-1 commitments (2026-08-11)**:

- **Interval representation: `Vec<RangeEntry>` per `(dev, inode)`**, scanned linearly on acquire/release.  Simpler than a balanced tree, correct against the four operations above, and appropriate for the small-N contention profile expected in MVP workloads.  A code comment at the definition site notes that a `BTreeMap<offset, RangeEntry>` or segment-tree swap is a candidate future optimization once real workloads expose N large enough for the scan cost to matter — the API surface (`try_acquire`/`release`/etc.) hides the representation, so the swap is behind an implementation boundary.
- **Per-range holder-set, not reader-count.**  `release_all_for_holder` needs precise identity; a bare count can't answer it.  Each `RangeEntry` carries `(offset, length, mode, holders: Vec<LockId>)` where `holders` is the set of overlapping readers (mode = `"r"`) or a single writer (mode = `"w"`).
- **Sequential-stream whole-file lock as a separate `Option<LockId>` flag per `(dev, inode)`, not a full-range interval-tree entry.**  Cheaper for the common case where a file has either sequential-only or positional-only traffic.  **Coexistence rule** (per FIP §1143 "a sequential stream conflicts with any positional stream and vice versa"): every `try_acquire` consults both structures.  Concretely — a *positional* acquire is admitted iff `sequential_holder.is_none()` AND no overlapping entry exists in the range list; a *sequential* acquire is admitted iff `sequential_holder.is_none()` AND the range list is empty.  The two structures never disagree because they are checked and mutated under the same `RwLock` write guard.  `release_all_for_holder(holder)` and `release_all_for_deploy(scope)` clear entries from both structures.  `is_locked(range)` (the consensus-mode unlink gate) returns true if `sequential_holder.is_some()` OR any range entry overlaps `range`.
- **Implicit-lock plumbing: Rholang-side (Option A).**  Positional methods (`bytesAt`, `writeBytesAt`, `readInto`, `readAtInto`, `writeFrom`, `writeFromAt`) explicitly call `fs_lock_range` in the library agent before invoking the byte-level native, with the matching `fs_release_lock` on stream close / method return.  The alternative — implicit acquire+release inside `fs_readAt`/`fs_writeAt` — would need cmode-branching inside the native (consensus gates, oracular hints; see §Mode-differentiated invariants) and would hide the lock from the Rholang deploy trace.  Option A keeps the mode-differentiated dispatch at the Rholang library layer where it already lives (per-cap cmode is a File-agent state cell), keeps lock lifetime visible to the Rholang caller for debugging and cost accounting, and composes cleanly with explicit `lockRange` (both paths go through the same native).  Invariant: byte-level natives (`fs_read`, `fs_readAt`, `fs_write`, `fs_writeAt`) are not reachable except through the lock-acquiring library methods — enforced by the URN filter (slice 31) which keeps `rho:io:fs:native:*` URNs out of user-reachable scope; genesis-scope Fs.rho is the sole holder.
- **`LockToken` agent inline in `File.rho`** (not a separate `LockToken.rho` module).  Issued by `File.lockRange`, released by `lockToken!release()`.  Single-method surface plus a default arm returning `[false, "FSERR_UNSUPPORTED", ...]`, matching every other agent in this FIP.  State is a single `stateP` cell holding the lock id; `release` is idempotent — second call after release returns `[false, "FSERR_CLOSED", ...]` mirroring `File.close` / `Stream.close`.  Inline placement chosen because (a) LockToken's `release` calls `fs_release_lock` which needs the same `fsBundleP` scope `File.rho` already has, (b) LockToken lifecycle is tied to its issuing `File` cap (per §13 recommendation `File.close` releases only that cap's tokens), and (c) nothing in the current spec suggests LockToken grows methods beyond `release` that would justify a dedicated module.  If a future spec extension adds `token!extend(newLength)` or similar, extraction to `LockToken.rho` is a mechanical refactor behind the agent-block boundary.  Attenuation (hand out "held token but no release") uses the standard §Ocap patterns > Attenuation via forwarder mechanism — no LockToken-specific machinery.
- **Constant metering weight for lock operations** (2026-08-11 commitment; feeds Phase 9 D3 rework per X-4).  `fs_lock_range` (both immediate `wait:false` and each `wait:true` acquisition attempt that resolves) and `fs_release_lock` emit a single `BillableTokenEvent::Primitive` per call with a constant weight in the same class as `fs_open` / `fs_close` (~100 in legacy `equality_check_cost` units; the D3 canonical weight is set alongside the other syscall weights when Phase 9 lands).  Not scaled by interval-tree lookup cost — under the `Vec<RangeEntry>` MVP a scan is cheap, and pricing lookup work would leak the internal data structure choice into consensus.  Under `wait:true`, the acquisition emits **one** `BillableTokenEvent` per resume (successful acquire, cancellation, or timeout), not per idle-tick — a blocked deploy does not burn phlo waiting.  Rationale: the resume is the only source-token event under the recursive metering kernel (§4 of cost-accounting-migration.md); wall-clock waiting is not a source-token consumption.
- **`File.close` implicitly releases every lock held via that File cap** (2026-08-11 commitment; spec §File > `close()` amended).  Implementation: `File.close` invokes `release_all_for_holder(holder)` on `LockRegistry` before dispatching `fs_close`, where `holder` is the per-cap holder identity used at acquire time (see §3 above).  Locks held on the same `(dev, inode)` via *other* File caps (opened separately via `Fs.openFile`) are not affected — the `(dev, inode)` key survives in `LockRegistry` as long as any cap holds it.  Rationale: a `File.close` on a cap that still holds locks would otherwise strand those locks in `LockRegistry` — technically deploy-end auto-release (§3 MUST) would sweep them, but the closed-File caller can no longer meaningfully do anything with the lock, so blocking others through it until deploy-end is a foot-gun.  Subsequent `lockToken!release()` on the now-orphaned token returns `[false, "FSERR_CLOSED", ...]` (LockToken already handles idempotent release; the release-after-close case flows through the same path).
- **Same-holder overlapping range acquires never conflict** (2026-08-12 refinement, added after slice 8a step-3 review surfaced the gap while mapping step-4 File.rho surgery).  `try_acquire_range` skips conflict against entries with matching `holder`, regardless of mode; sequential-vs-positional exclusion is not relaxed (matches FIP §1143 "one active sequential stream per File").  Each same-holder acquire still mints a fresh `LockId`; each `release(id)` still removes exactly the one matching entry; state-shape unchanged.  Rationale: without this rule, a caller holding an explicit `lockRange(0, 1024, "w")` on their own cap would trip a W-vs-W self-conflict on any subsequent positional method call through that cap, defeating the spec's compositional promise at §Explicit locks.  The File-agent dispatch loop's `stateP`-linear-receive already serializes intra-cap operations at the Rholang layer, so no kernel-fd race hides behind this rule — it just lets `LockRegistry` reflect the same "no self-conflict" semantic Rholang callers observe.  Cross-cap coordination remains strict (different holders → any conflict → `Busy`).  Spec §Range locks and §Race-window notes amended 2026-08-12 to explicitly document the same-holder rule; earlier drafts didn't distinguish holder identity and were internally inconsistent with the compositional-promise example at §Explicit locks (this doc's §1159-1167 usage sketch).
- **`bytesAt(offset, Nil)` unbounded-read pessimistic-to-EOF lock** (2026-08-12 refinement, added during step 4d-2b implementation review).  The spec's original §Range locks language (`bytesAt(offset, length)` locks `[offset, offset+length)`) assumed `length` is a caller-supplied Int, but `bytesAt` also accepts `length = Nil` for read-to-EOF.  Implementation choice: for the Nil case, acquire a pessimistic `[offset, offset + 2^62)` lock — 4 EiB extent, wider than any real file, with headroom against `i64::MAX` overflow in the LockRegistry's saturating-add overlap check.  Cross-cap writers at any offset ≥ the read's start conflict, matching the "reading an entire mutable file" semantic.  Rejected alternatives: `i64::MAX - off` (insufficient headroom, and harder to eyeball in registry state during debugging); "no lock" (violates §Range locks' "stream's lifetime" invariant); "acquire small lock and extend on each refill" (LockRegistry has no extend op, and locks would leak between the read finishing chunk N and the acquire for chunk N+1).  The 2^62 sentinel is a hardcoded Rholang literal in File.rho — consensus-observable via the composed-genesis hash; a network-wide change requires the standard hard-fork discipline.  Spec §Range locks amended 2026-08-12 to explicitly document the pessimistic-to-EOF rule.
- **Cursor-relative methods derive lock range via `fs_tell` snapshot** (2026-08-12 refinement, added during step 4d-1 implementation review).  Spec §978 said `readInto` / `writeFrom` "take the same implicit range locks as `bytesAt` / `writeBytesAt`" without specifying HOW the lock range is determined for cursor-relative methods where offset is not a caller argument.  Implementation choice: issue `fs_tell` to snapshot the cursor immediately before `fs_lock_range`, then lock `[cursor, cursor + N)` where `N` = `buf.remaining()` (reads) or `bytes.length()` (writes).  Two extra syscalls per operation (tell, release, plus native).  TOCTOU between snapshot and read/write is closed by the File-agent dispatch loop's `stateP`-linear-receive — no other operation on the same cap advances the cursor between snapshot and syscall.  Rejected alternatives: no lock (violates §978); whole-file lock (pessimistic beyond need); pass-through offset via caller (would require FIP-breaking API change).  Spec §Concurrency partition amended 2026-08-12 to explicitly document the fs_tell-snapshot approach.
- **`writeLines` atomicity is per-line, not per-writeLines** (2026-08-12 refinement, added during step 4e-1 implementation review).  `writeLines` releases `stateP` early so `writeLinesLoop` can call back into `writeLine` per inner iteration; each `writeLine` acquires + releases a whole-file sequential lock independently.  Between two internal writeLine calls, another sequential caller (from another File cap on the same physical file, or from another Par branch on this cap) can slip in and interleave its own writes.  A caller who needs cross-call atomic multi-line writes cannot achieve it via a same-cap `lockRange` (sequential is strict same-holder per §Slice-1 commitments' same-holder-skip scope — sequential-vs-anything exclusion applies to the same cap); the workaround requires a DIFFERENT cap on the same `(dev, inode)` holding an outer range lock to block cross-cap sequential attempts while this cap runs writeLines.  Rejected alternative: hoisting the sequential lock to writeLines' entry with a public-vs-internal writeLine split.  Deferred as YAGNI unless a concrete use case surfaces.  Spec §Sequential vs. positional amended 2026-08-12 to explicitly document the atomicity scope for aggregating methods (writeString and writeLines).

All X-1 sub-questions resolved: separate `LockRegistry` (not a `RootIdentityRegistry` extension); row shape derived from four operations; interval representation `Vec<RangeEntry>`; per-range holder-set with same-holder-skip rule; separate sequential flag with coexistence rule; Rholang-side implicit-lock plumbing; WAL post-decision journaling with H-6 outcome variant.  X-2's blocked-then-cancelled ordering concern is subsumed by the Rig-protocol commitment (2026-08-11) — every acquire outcome, including cancellation, produces a matching ack Produce, so H-R3 drain treats all cases uniformly.

### Mode-differentiated invariants under `LockRegistry` (2026-08-11 refinement)

Per the observation that oracular mode is defined by *observing* an externally-mutating filesystem — the host's rm, mv, symlink-add operations happen without the node's knowledge and are the whole point of oracular use cases — the semantics of `LockRegistry` (and adjacent invariants) diverge by cmode:

**Consensus mode** (node is the sole mutator of consensus-static paths):
- `LockRegistry` is a hard invariant.  Two Rholang callers holding distinct caps on the same physical file see a single coordination table; overlapping range conflicts return `FSERR_BUSY` deterministically.
- `fs_remove_file` / `fs_remove_dir` consult `LockRegistry` at handler entry and refuse (`FSERR_BUSY`) if any lock is held on `(dev, inode)`.  This closes the "unlink-while-locked → lock survives on a now-orphan inode" race.
- `RootIdentityRegistry`'s boot-captured `(dev, inode)` is stable for the run; H-5's fail-closed check on drift is correct — any drift is an attack.
- Path resolution is stable within a deploy because the node is the sole mutator; `Dir.stat(rel)` followed by `Dir.openFile(rel)` on the same cap resolve to the same physical file.

**Oracular mode** (host FS mutates under the node):
- `LockRegistry` is a best-effort in-process coordination hint between *this node's own Rholang callers*.  It correctly serializes Alice-and-Bob-inside-this-node contention on the same physical file (their fds, opened at different times, both landed on `(dev, ino_A)` because the host hasn't perturbed things in between).  It does not and cannot prevent external processes from writing to `ino_A` in parallel, and does not need to — oracular callers have already accepted that external mutations happen.
- `fs_remove_file` / `fs_remove_dir` do NOT consult `LockRegistry`.  The caller asked to delete a file; if someone in this node holds a lock, the delete succeeds anyway (matches host semantics — you can `rm` a file even while another process has it open).  Log-warn on locked-file delete for observability (`tracing::warn!` at `target = "f1r3fly.fs.oracular"`, message body `"oracular unlink of locked file (dev={}, ino={}) — {N} holder(s) will observe subsequent errors on path-based calls; fd-based calls remain valid until close"`); do not gate.
- **Holder discovery of external delete is via polling, not push.**  When Alice's file is deleted externally (by another process, or by another Rholang deploy calling `fs_remove_file`), the runtime does NOT push a notification onto Alice's cap or her lock token.  Alice discovers the deletion the next time she calls a *path-based* method on the affected file (which returns `FSERR_IO` / `FSERR_NOT_FOUND` from the underlying syscall's `ENOENT`), or the next time she calls a *fd-based* method that produces a kernel-observable symptom (e.g., `fs_write` after the file's directory entry is gone still succeeds against the fd's inode; `fs_stat` by cached-canonPath fails).  Rationale: matches POSIX semantics exactly, avoids inventing a Rholang-side push-notification protocol, and keeps oracular caps' behavior predictable from operator experience with `rm` while another process has the file open.  Alice's `LockRegistry` entry stays valid until she `release`s or her cap closes; unlocking a lock on a since-deleted inode is a no-op cleanup, not an error.
- **`RootIdentityRegistry` skips registration for oracular roots entirely** (2026-08-11 commitment).  At boot, `create_casper_infrastructure` filters the operator-provisioned bundle by cmode before calling `root_id_registry.register(...)`: only entries with `BundleConsensusMode::Consensus` are registered.  `safe_descend_verified` then consults the registry with `registry.get(root)`; a `None` return (unregistered oracular root) short-circuits the H-5 identity check.  Native code stays cmode-agnostic — the cmode fork happens exactly once, at boot-time registration.  Rejected alternative: register oracular roots with a flag and branch inside `safe_descend_verified`.  More knobs, no upside; the boot-time filter is the cleaner surface.  H-5's fail-closed semantics remain intact for consensus roots (attack detection); oracular roots gain the freedom operators need for legitimate in-place mutations like log rotation.
- Path-based Dir methods (`stat`, `chmod`, `remove*`, `rename`, `copyFile`, `openFile`, `openDir` by rel) are TOCTOU-racy by design.  Two consecutive calls on the same cap may resolve to different physical files.  All security checks (quarantine, non-regular-file reject, symlink-appearing-post-boot check, mode gate) run per-syscall as they already do; no caching at cap-open time is safe.
- Fd-based File methods (`chars`, `bytes`, `bytesAt`, `writeBytes`, `seek`, `tell`, `size`, `truncate`, `flush`) are stable across host mutation because the kernel fd holds the inode reference — Alice's `File.chars()` continues to stream from the physical file her fd was opened against, even if the path was renamed or unlinked under her.

**Cross-mode summary**: consensus and oracular caps live in the same `LockRegistry`; the mode-differentiated behavior is at the handler layer (which handlers consult the registry, which handlers gate on it), not in the registry itself.  A single node running mixed cmode caps sees a uniform registry; each syscall reads its cap's cmode and dispatches accordingly.

**Eviction under both modes**: `LockRegistry` entries evict on last-cap-close.  Under consensus, `fs_remove_file`'s pre-check makes intervening-unlink impossible.  Under oracular, intervening-unlink is possible but harmless: Alice's fd holds the original inode alive; her `LockRegistry` entry remains keyed on `(dev, ino_A)` until she closes; any new file created at the same path gets a different inode (kernel doesn't hand out in-use inode numbers), so its `LockRegistry` lookup misses and it doesn't spuriously conflict with Alice.  The only inode-reuse concern is *after* Alice closes and evicts — which is safe because there's no lock to spuriously conflict with.

### X-2 supplement — `wait: true` acquisition ordering

The H-R3 log-order-drain fix (Phase 7 slice 30c) re-orders WAL entries by matching each entry's ack-channel-hash against `deploy_log`'s Produce events.  Every current Phase-7 WAL entry corresponds to a syscall that eventually produces its reply within the same deploy — so every entry finds a matching Produce in log order.  Under Phase 8's `lockRange(..., {"wait": true})`, a blocked acquire may (a) unblock within the deploy (normal drain works), (b) block past deploy-end and get auto-released on cleanup with no Produce ever firing, or (c) block, be cancelled, and produce an error reply — with the WAL entry's ordering relative to concurrent Produces determined by scheduler nondeterminism.

Cases (b) and (c) break the H-R3 determinism guarantee because there's no `deploy_log` Produce to match the WAL entry's sidecar hash against.  H-R3's orphan-tail fallback then falls back to insertion order, which is scheduler-dependent — the exact class H-R3 was designed to prevent.

Agreed Phase 8 rollout:

1. **§MVP (fail-fast only).**  Deliver `lockRange` + implicit range locks in `wait: false` mode only.  Conflict returns `FSERR_BUSY` immediately; every acquire produces its reply within the same tokio dispatch.  WAL journaling matches `fs_read`'s post-decision pattern: `LockAcquire { range, mode, outcome: Success | Failure(FSERR_BUSY) }` appended after the acquire attempt resolves.  Preserves the Phase-7 determinism invariants exactly — every WAL entry has a matching Produce; drain is unchanged.

2. **§follow-up (`wait: true`) — Rig-protocol coordination** (2026-08-11 commitment after inspecting `rspace++/src/rspace/trace/event.rs` and `rspace++/src/rspace/replay_rspace.rs`).  Adds blocking acquisition, reusing the OpenAI/Ollama/gRPC non-deterministic-Produce infrastructure that already ships in production:

    - **Success path**: some other deploy releases the lock → the lockRange native sends a normal Produce on the acquire's ack channel carrying `[true, lockToken]` → follower's Consume-Produce-COMM replay matches via the existing `MultisetMultiMap<IOEvent, COMM>` in `ReplayRSpace::replay_data`.  Zero new machinery.
    - **Cancellation / timeout path**: on the leader, the lockRange native synthesizes an error Produce on the ack channel via `Produce::with_error()` carrying `[false, "FSERR_CANCELLED", ...]` (mirroring `reduce.rs:369`'s `DispatchType::FailedNonDeterministicCall` branch used today for external-service failures).  The synthesized Produce enters the deploy log; follower's replay finds the recorded outcome in `replay_data` and dispatches it without re-attempting the block.  `Produce`'s identity is `hash`-only (`PartialEq`/`Ord`/`Hash` ignore the `is_deterministic`/`output_value`/`failed` fields), so the marked Produce matches its own slot on the follower.

    **Rejected alternative — deploy-scope deterministic timeout**: bends lock semantics from wall-time to logical-time (function of `(deploy_hash, acquire_index)`), forces selection of a `TIMEOUT_STEP_BOUND` constant that must stay under `reduce.rs::eval_inner`'s AST/term-count ceiling under D3, and offers no upside now that Rig-protocol has zero-schema-change reuse via the existing non-det-Produce infrastructure.

    **Handler-side work for the follow-up slice**: (a) lockRange's cancellation branch synthesizes the error Produce on the ack channel with `with_error()` + `update_produce`; (b) H-R3's log-order drain treats cancelled acquires uniformly with successful ones (both produce a matching Produce in `deploy_log` — the drain doesn't care about outcome); (c) no changes to `Event`, `Consume`, `COMM`, or `ReplayRSpace::rig`.

    **Waiter ordering — FIFO for the follow-up MVP** (2026-08-11).  When multiple `wait: true` acquires are blocked on the same conflicting range and a release makes room, the waiter that entered the queue first wins.  Implementation: `RangeEntry` (or a sibling per-range queue) carries `waiters: VecDeque<(LockId, ack_channel_par, request)>`; release scans for waiters whose ranges now fit and dispatches them in insertion order.  Determinism across validators is preserved by the Rig-protocol layer above — every validator sees the leader's captured ordering via `deploy_log`, so the FIFO decision is only load-bearing on the leader.  A code comment at the queue site notes that priority / fairness / hash-derived shuffling (e.g., `(deploy_hash, acquire_source_path)` lexicographic to spread traffic across cooperating deploys) are candidate future schedulers once real workloads expose starvation or head-of-line-blocking pathologies; the API surface hides the choice.

    MVP (§1 above) remains unblocked; this commitment closes the "does replay path need new machinery" question so the follow-up slice can start on lockRange handler work directly.

    **Slice 8b concrete implementation steps** (fresh-session pickup, 2026-08-12):

    1. **Extend `LockRegistry` with waiter queue**: add `waiters: VecDeque<Waiter>` field per `FileLockState` (or per-`RangeEntry`; see comment above).  `Waiter` carries `(request_range, request_mode, holder, deploy, ack_channel_par)`.  Adjust `try_acquire_range` / `try_acquire_sequential` to accept a `wait_mode: WaitPolicy` param; on conflict under `WaitPolicy::Wait`, enqueue instead of returning `Err(Busy)`.
    2. **Modify `release` and sweep methods** to wake waiters: after removing entries, scan `waiters` for any whose range now fits; move them to admitted state and prepare an ack Produce (see step 4).
    3. **Add cancellation entry point**: `LockRegistry::cancel_wait(lock_id) -> Option<Waiter>` for the deploy-end sweep to abandon parked waiters + emit failure acks (see step 5).
    4. **Modify `fs_lock_range` / `fs_lock_sequential` natives** to accept a `wait: Bool` arg (arity 8/5, up from 7/4).  On `wait: true` conflict: register the waiter; DO NOT produce a reply yet.  When the waiter admits (via release-triggered wake), the native's parked task sends the success reply on the ack channel; when the waiter cancels (deploy-end), send a synthesized error Produce via `Produce::with_error()` + `update_produce` (mirroring `reduce.rs:369`).  Composed-source arity table + genesis golden hex re-roll.
    5. **Wire deploy-end cancellation into slice-8a step-5 auto-release hook**: in addition to `release_all_for_deploy(scope)`, iterate parked waiters for that deploy and cancel each (synthesized error acks).
    6. **Add File.rho / LockToken plumbing** for the `wait: true` option: route `{"wait": true}` from Rholang caller down to the native's `wait` arg.  Positional methods (`bytesAt`, `writeBytesAt`, etc.) inherit via the same options-map argument (spec §1172).
    7. **Tests**: `wait: true` blocks until holder releases; multiple waiters admit FIFO; cancel-on-deploy-end synthesizes `FSERR_CANCELLED` reply visible to caller; H-R3 log-order drain matches the synthesized Produce (belt-and-suspenders with the concurrent-ack regression from X-3).

    **Effort**: 2-3 days.


### X-3 supplement — cost-accounted-rho impact on X-1 / X-2 (2026-08-08)

Recorded after investigating `origin/feature/cost-accounted-rho` (D3 / DR-9, `runtime.rs::play_deploy_with_cost_accounting_cosigned`), which is the in-flight branch that will merge into `dev` and eventually meet Phase 7 / Phase 8 File I/O.  The model shift is:

- **Deploy boundaries at the Casper layer are unchanged.**  `process_deploy_cosigned` still takes a soft checkpoint before eval, calls `evaluate_cosigned(&cosigned).await` to quiescence (all `FuturesUnordered` branches drained + errors aggregated in stable term order at `reduce.rs:301`), drains the event log via `take_event_log`, builds a `ProcessedDeploy`, and reverts the soft checkpoint on failure.  `play_deploys_for_state_cosigned` iterates deploys sequentially.  Per-deploy scoping — the substrate that WalDeployScope, H-2 replay, H-5 root registry, H-6 outcome variant, H-7 play-vs-replay independence, and M-5 state-read journaling all sit on — survives intact.
- **Intra-deploy concurrency is now real.**  Sub-terms of a single deploy are `tokio::spawn`ed and drained through a single `FuturesUnordered` (`reduce.rs:276–298`); the Phase 1 / Phase 2 dispatch barrier is gone.  Two syscalls issued from parallel branches of one deploy can genuinely race at the `rspace event_log` mutex.
- **`OutOfPhlogistonsError` no longer aborts user evaluation.**  D3 (DR-9) installs `Cost::unsafe_max()` on the budget at `runtime.rs:1278` — accepted deploys run UNMETERED-FOR-LIVENESS.  Fundedness was proven upstream at the block-assembly acceptance gate against Σ⟦s⟧; the settlement debit is applied once at block close.  `total_cost()` still counts per-COMM cost for the fee, but the runtime never raises OOP mid-deploy.  Non-termination is bounded solely by the AST/term-count guard in `reduce.rs::eval_inner`.

**X-1 impact — the Rust-side lock struct is *more* correct under D3, not less.**  The 2026-08-07 rationale for a Rust struct over a Rholang lock agent cited RSpace soft-checkpoint revert as the mechanism that recovers a mid-deploy lock-take failure.  Under D3 the soft-checkpoint still fires (on the `eval_result.errors.is_empty() == false` branch of `process_deploy_cosigned`), so that argument is unchanged.  What D3 removes is the OOP-abort path that used to be a *second* implicit source of mid-deploy termination; a Rholang lock agent could previously have been broken by OOP mid-take, and now can also be broken by the AST/term-count guard tripping mid-take.  Either way the Rholang idiom loses its message; the Rust struct closes both by construction.  No memo change needed to §X-1 itself.

**X-2 impact — the `wait: true` follow-up must not lean on OOP as a backstop.**  The Phase-8 §MVP is unchanged (fail-fast in the same tokio dispatch; every acquire produces its reply; H-R3 determinism preserved).  The §follow-up options need one addition:

- **AST/term-count guard is the sole non-termination backstop under D3.**  A `wait: true` acquire that never fires runs until `reduce.rs::eval_inner` trips the term-count guard.  That bound is deterministic (guard trips on step count, not wall-clock) but is much looser than OOP was.  The Rig-protocol option is unaffected — leader records the cancellation position, followers replay verbatim.  The deploy-scope deterministic-timeout option needs its "give up" moment defined *below* the AST/term-count ceiling so the follower never trips the outer guard on the timeout replay; concretely, the timeout function `(deploy_hash, acquire_index) → step_count` must have a codomain strictly less than the eval_inner ceiling.

**H-R3 under FuturesUnordered.**  H-R3's drain matches WAL entries to `deploy_log` Produces by ack-channel-hash, which is set-membership and therefore order-independent.  The ordering nondeterminism of the append itself (multiple branches racing to append their Produce to the mutex-protected `event_log` in `rspace.rs:285`) doesn't break the drain, but it does make the ack-channel-hash 1:1 uniqueness assumption more load-bearing than it was under the sequential eval path.  Add a Phase-8 regression test that runs a deploy issuing N concurrent syscalls with distinct ack channels and asserts drain still matches 1:1 across 100 randomized `tokio` scheduling shuffles; a collision or a mismatch would surface as an orphan-tail fallback (H-R3's insertion-order path) which is exactly the class H-R3 was designed to prevent.

**Merge posture.**  `fileio-phase-1-2` (this branch) and `origin/feature/cost-accounted-rho` are disjoint on file surface — cost-accounting doesn't touch `rholang/src/rust/interpreter/io/`.  A behavioral integration pass is required at merge time: run `fs_wal_spec` and `file_dir_check` under the new `FuturesUnordered` eval loop and confirm deploy_log ordering variance doesn't break WAL drain matching.  The H-R3 concurrent-ack regression above is the first test to write.

### X-4 supplement — earlier-phases language reconciliation (2026-08-11)

X-3 covered X-1 / X-2 / H-R3 under D3.  This supplement walks Phase 0 → Phase 9 for language and design assumptions that reference the retired externalized cost model (`CostManager` / `ChargingRSpace` / storage-cost refunds / OOP-abort) and specifies which need edits, which don't, and where.

**Phases 0 through 8 — delivered code is not affected.**  D3 is a runtime-side migration inside `rholang/src/rust/interpreter/accounting/`, `metering.rs`, and `reduce.rs`'s eval loop.  It does not touch any of:

- `rholang/src/rust/interpreter/io/` (the entire File I/O native surface — handlers, WAL, snapshot, path, mode, stat, nss, response, consensus_fingerprint, handle_table).
- `casper/src/main/resources/{Fs,File,Dir,Buffer,Rows,Stream,Stdin,Stdout}.rho` (the library agents).
- The `casper/src/rust/genesis/contracts/fs_genesis.rs` composition and the `StandardDeploys` wiring.
- The node-side static-provisioning surface (`file_io_provisioning.rs`, `boot_validation.rs`, `provisioning_merge.rs`, `snapshot_config.rs`).
- Boot-time snapshot / WAL cadence, LFB-hook, join-protocol manifest, or the URN filter.

The delivered code goes through whatever cost-accounting frame the interpreter presents.  Under the current interpreter the natives call `CostManager::charge()`; under D3 the natives will emit `BillableTokenEvent::Primitive` descriptors (a mechanical port, one line per handler) and `RuntimeBudget::reserve_canonical_with_cost` will replace `CostManager::charge()` at the same call sites.  No design decision is on the table for Phase 0-8; the port is a merge-time task, not a re-plan.

**Where language references retired APIs.**  Three call sites in this document name the retired API by name.  All are historical descriptions rather than load-bearing designs, and none block the merge; update-at-merge-time:

1. Phase 1 §Native primitives, "**Cost-accounted** — `CostManager::charge()` at handler entry, proportional to work done." (line ~51).  Language should say: "Cost-accounted — a deterministic weighted `BillableTokenEvent` descriptor is emitted at handler entry via `RuntimeBudget::reserve_canonical_with_cost` (D3) or `CostManager::charge` (pre-D3), proportional to work done."
2. §Reference points, "**Cost accounting**: `rholang/src/rust/interpreter/accounting/costs.rs` — per-op cost functions; `accounting/mod.rs:43-69` for the `charge()` primitive." (line ~833).  Under D3 the `accounting/mod.rs` surface grows from ~200 lines to ~2600 lines dominated by `RuntimeBudget`, `BillableTokenEvent`, `Sig`, `Token`, and `Lane`; the pointer should be broadened to "`accounting/mod.rs` — `RuntimeBudget` reservation surface plus the pre-D3 `charge` primitive; `costs.rs` — per-op weight constants" or similar.
3. §Buffer library size on-chain, "the persistent-dispatcher storage cost per instance is per-runtime and never refunded" (line ~823).  Under D3, `storage_cost_produce`/`storage_cost_consume` are retired from the user-deploy path (`cost-accounting-migration.md` §5.9.1 / §5.9.4); the persistent-consume dispatcher's cost surfaces instead as the initial recursive-metered-gate token consumption at agent instantiation.  Language should switch from "per-instance storage cost" to "per-instance recursive-metering cost at agent-block instantiation".  The observation that `close()` is the only in-deploy reclamation path is preserved: reclamation is the token sweep (`sweep_unconsumed_tokens`, migration §5.8.2) at deploy-end + explicit `close()` for byte storage, not a refund.

**Phase 9 (Cost accounting scaffolding) — reframe deliverables.**  Phase 9 is undelivered and is the phase where the model shift is load-bearing.  As currently written (line ~694) it targets `CostManager::charge()` insertion with placeholder constants that "the Cost FIP will calibrate".  Under D3:

- The `CostManager`-shaped call site no longer exists on the user-deploy path.  Charges are emitted as `BillableTokenEvent`s consumed by the metering kernel in canonical descriptor order.
- Weights are **consensus-critical from day one** — `total_cost()` counts them, `ProcessedDeploy.cost` records them, and the settlement debit at block close uses them.  There is no "placeholder tunable constant" window in which weights can drift between validators; a weight change is a hard-fork.
- Rholang library-method entry points do NOT need explicit charges.  The recursive metering kernel authorizes source-token consumption at every rule-1..5 boundary; library-agent method dispatch is not a separate metering surface.  The native side is the only place where explicit weight emission is required.
- The materialization caps (`toString(cap)`, `toByteArray(cap)`, `toList(cap)`) remain valuable as defense-in-depth against unbounded reply payloads — nothing has changed there.
- `readInto` vs. `read` cost decomposition (the paragraph noting `readInto` = native read + substitution charges per parked chunk) is retired language.  Under D3, `readInto` cost is the sum of the native read event and the byte-throughput weight of the `writeBytes` calls; there is no `storage_cost_produce` refund path to differentiate the two.

Phase 9's deliverables list should be rewritten to: (i) enumerate per-native `BillableTokenEvent::Primitive` weight functions with hard-fork discipline; (ii) drop the Rholang library-method charge insertion; (iii) preserve materialization caps; (iv) coordinate weight activation with the eventual cost-accounted-rho merge's hard-fork block-height trigger (`cost-accounting-migration.md` §6 step 22).

**Phase 5 / Phase 6 concurrency assumption.**  Any Phase-5/6 reader who assumes "two Par-branches in one deploy will serialize because the eval-loop dispatches phase 1 before phase 2" should recheck under `FuturesUnordered` (`reduce.rs:276-298`) — those two branches now genuinely race.  Per-Rholang-agent dispatch is still serialized at the RSpace layer (`for(_ <- @(*this)){...}` continuations are consumed one at a time), so File-agent and Dir-agent method dispatch is safe by construction; but two Par-branches issuing writes to *different* files can now genuinely interleave.  H-R3's log-order-drain is what preserves WAL determinism against this interleaving; the X-3 concurrent-ack regression test above is the belt-and-suspenders.

**Buffer library dispatcher accounting.**  §Buffers documents the persistent dispatcher as "not refunded" under the pre-D3 storage-cost model.  Under D3, the dispatcher's per-instance cost is the recursive-metering cost at agent-block instantiation (a fixed source-token cost), and `close()` remains the only in-deploy reclamation path for byte storage; the dispatcher continues to require deploy-end token sweep / GC.  The spec-side language ("close() is the only in-deploy, refunding reclamation") should switch to "close() is the only in-deploy byte reclamation; dispatcher and tombstone reclamation await deploy-end sweep" when the spec is refreshed alongside merge.

**PB-M-13 startup re-close pass (Phase 7 §371).**  This deliverable was already explicitly motivated by "with tokenized cost accounting, deploys no longer have run-to-completion semantics; File agents outlive their originating deploy".  D3 confirms this motivation.  Slice 28's fd-watermark implementation (delivered) provides the aliasing protection; the stateP-rewrite variant was correctly deferred.  No further change under D3.

**PB-M-14 consensus WAL / PB-M-15 snapshots.**  Under D3 the WAL and snapshot surfaces remain per-deploy scoped by `process_deploy_cosigned` and per-block-window by the LFB hook.  Every Phase 7 fix (WalDeployScope, H-2 replay, H-4 signed manifest, H-5 root registry, H-6 outcome variant, H-7 play-vs-replay independence, M-5 state-read journaling, H-R3 log-order drain) sits inside those boundaries.  Boundaries are unchanged under D3; fixes survive.  The one D3-driven risk is intra-deploy ack-channel-hash uniqueness under `FuturesUnordered`, covered by the X-3 regression test.

**Summary of what needs editing at merge time:**

- **Rewrite Phase 9 in place** — target `BillableTokenEvent` + `RuntimeBudget::reserve_canonical_with_cost` instead of `CostManager::charge`; note consensus-critical weight discipline; drop Rholang library-method charge insertion; preserve materialization caps.
- **Three inline language updates** — Phase 1 §Native primitives cost-accounted bullet, §Reference points cost-accounting entry, §Buffer library size on-chain paragraph.
- **Spec refresh** — the FIP §Cost accounting section (line 1416+ of `2026-07-24-File-IO.md`) uses "CostManager::charge() (or the equivalent)" future-proofed language, so a minimal edit suffices; §Buffers > Reuse-is-refunded needs the D3 shift described above.
- **No re-plan of delivered phases** — the code goes through whatever cost frame the interpreter presents.  Port is mechanical.

## Phase 8 — delivered and pushed (2026-08-13, tip `1d38f829`)

`LockRegistry` MVP + `wait: true` Rig-protocol coordination + options-map plumbing across all bounded and stream-lifetime File methods.  See git log on `fileio-phase-1-2` from `1d38f829` back through slices 8a / 8b / 8c / 8d for per-slice deliveries.  Whole-Phase-8 review found no blocking issues; three follow-ups (MAX_WAITERS_PER_FILE cap, cross-deploy mutual-wait deadlock, cursor-relative TOCTOU docstring) live in the Deferred catalog below.

**Non-blocking deferrals from Phase 8 review** (kept here as they surface periodically):

- **Native arity tightening** — legacy arity-7/arity-4 fsLockRange/fsLockSequential shim still accepted alongside arity-8/arity-5.  Removing requires ~300 test-caller migrations; standalone slice.
- **MAX_WAITERS_PER_FILE cap** (NB-3): hostile deploy → large transient parked-waiter alloc.  Bounded by deploy-end sweep; cap would be defense-in-depth.
- **Produce::with_error() for cancellation replies** (NB-4): not needed until reporting-rspace ships.
- **Cross-deploy mutual-wait deadlock** (NB-7): two deploys each wait:true on the other's lock never release.  Beyond Phase 8 scope.
- **LockRegistry Drop test** (N4) and **helper-binding drift source-scan pin** (F-2): behavioral pins exist; source-scan would be defense-in-depth.

## Phase 9 — delivered (2026-08-23, slices 9a + 9b + 9c-i + 9b-iv-follow-up + 9c-ii)

Per-native cost emission wired at handler entry via
`BillableTokenEvent::Primitive` (Path B chosen — cost-accounted-rho
merged first, so no port work).  Weight table + golden pins in
`rholang/src/rust/interpreter/io/costs.rs` +
`rholang/tests/fileio_cost_spec.rs`; every FS native charges at
handler entry per §Phase 9 above.

Deferrals from initial Phase-9 that later landed as follow-ups:

- **9b-iv per-entry two-branch charges**: `fs_entries` now charges
  the `FS_ENTRIES_PER_ENTRY * n` supplement on both leader (from
  fresh `spawn_blocking` reply) and replay (from `previous`)
  branches via `extract_ok_list_len`.  `fs_entries_stream` (stub
  returning FSERR_UNSUPPORTED — no entries to charge for) and
  `fs_remove_dir` (reply shape lacks `n_deleted`) stay setup-only
  with the source-scan pin
  `entries_stream_and_remove_dir_charge_setup_only_pending_blocker_resolution`
  documenting each blocker.
- **9c-ii Buffer materialization cap**: `Buffer.rho::toByteArray(@cap)`
  with FSERR_QUOTA_EXCEEDED on `ell > cap`; 4 File.rho callers pass
  `67108864` (MAX_WRITE_BYTES).  4 runtime pins in `file_dir_check`
  exercise each gate arm.

Post-Phase-10 follow-up (delivered 2026-08-25):

- **Cost-regression sample-workload harness** (`bd4bc70c7` + doc-lint
  fixup `d0be7fd9b`): new file `rholang/tests/fileio_cost_runtime_spec.rs`
  hosts `create_metered_runtime()` (in-memory rspace + fs-native
  URN filter disabled) + first two tests: `fs_entries_five_children_
  charges_supplement_at_runtime` and `fs_entries_empty_dir_charges_
  setup_only_at_runtime`.  Runtime-layer pin of the 9b-iv per-entry
  supplement wiring: 5-child fixture consumes 3255 units (lower
  bound `fs_entries_cost(5) + 5 * fs_stat_cost() = 710`, harness
  overhead ≈ 2545, 5000-unit ceiling above lower bound).  Empty-dir
  boundary pin catches an off-by-one that would fire the supplement
  with n=1.  Reads consumed cost from `EvaluateResult.cost.value`
  (which is `self.c.total_cost()` at the end of `inj_attempt`) —
  the module docstring warns future readers that `runtime.cost.get()`
  returns "budget remaining" after `inj_attempt` resets from
  `initial_phlo`, so `initial - remaining` overflows.

Still open (see Deferred items catalog below):

- **9c-iii Buffer pairwise-merge growth test** — blocked on the
  pairwise-merge refactor itself.

Deferred to a future Cost FIP (out of Phase 9 scope):

- `readInto` vs. `read` cost decomposition.
- Full weight calibration.

## Phase 10 — status and E2E test inventory

Phase 10 landed on `origin/fileio-phase-1-2` at tip `5d98daa21`
(2026-08-23).  The section below is the current checklist and
enduring reference material.  Historical per-session progress
narratives (2026-08-13 canonical-examples + review-pass, 2026-08-23
pickup) live in the git log and commit messages.

### E2E test file inventory (canonical reference)

Under `casper/tests/genesis/contracts/`:

- `fileio_examples_spec.rs` — canonical-example regressions + Phase-10 additions (chown / lockrange / static / membrane / readonly-forwarder / stdio / parallel + 3-way lockRange no-starvation).  Two ignored (blocked on PB-B-5 Allocator publish; foldConcurrent positive-path pending Stream.rho method landing).
- `fileio_error_matrix_spec.rs` — per-error-code integration matrix (12 tests: FSERR_BAD_ARG / UNSUPPORTED / CLOSED / BUSY / ALREADY_EXISTS / QUOTA_EXCEEDED / BAD_ARG-on-dir-kind).
- `fileio_fs_spec.rs` — Fs / Stdin / Stdout surface (default-mode inference, mode-string sweep, Stdin/Stdout default arms, `r+` drift pin).
- `fileio_stream_spec.rs` — LineStream chunk/foldChunks/foldConcurrent/mapReduce all → FSERR_UNSUPPORTED; fold on closed stream → FSERR_CLOSED.
- `fileio_file_spec.rs` — cursor semantics (seek/tell), size, readN edge cases, truncate roundtrip + on-disk verify, close gates.
- `fileio_consensus_replay_spec.rs` — Consensus vs Oracular stat field omission (Layer 1 only; Layer 2 leader-follower byte-identity replay blocked on two-runtime harness).
- `fileio_dir_spec.rs` — Dir.exists, openFile mode attenuation, openFile→readN roundtrip + Phase-10 mutation E2E (removeFile / removeDir(recursive) / rename / copyFile with on-disk verification).

Under `rholang/tests/`:

- `fileio_cost_spec.rs` — per-native cost helpers golden pins + source-scan pins for handler wiring, entries-family two-branch charges, stream chunk cap, Buffer materialization cap, stdio-oracular invariant.
- `fileio_lifecycle_spec.rs` — fd-table rollback via production `create_soft_checkpoint` / `revert_to_soft_checkpoint` path (single + nested checkpoints).
- `fileio_stream_argvalidation_spec.rs` — foldConcurrent / mapReduce argument validation + Stream.chunk boundary matrix (65536 / 65537 / 1_000_000).

### Rholang / harness gotchas (enduring reference)

Recorded because each cost real debugging time; each still relevant for any future Rholang-side work:

- **`...` splat in send position is illegal.**  Rholang grammar (`rholang_mercury.cf` — `ProcRemainderVar` line 185) only accepts `...` inside collection destructures (list / set / map), NOT as splats in send positions.  The FIP's §Ocap-patterns pseudocode `underlyingFile!(returnCh, method, ...args)` cannot land verbatim.  Membrane / readonly-forwarder examples specialize per-method-arity as workaround.  Recorded in `fileio_membrane.rho` and `fileio_readonly_forwarder.rho` docstrings.
- **`Fs.openFile("name", {})` defaults `requestedMode` to `"r"`.**  Empty options ≠ "inherit provisioned mode".  Write-capable bundles need explicit `{"mode": "rw"}`.  See Fs.rho line 247.
- **`File.bytes()` emits 1-byte `ByteArray`s, not integer bytes.**  Spec §225 pseudocode `returnCh!(acc + byte)` is wrong; user code needs `byte.nth(0)` to extract the Int.  See fileio_parallel.rho.
- **`seek` whence values are `"set"` / `"cur"` / `"end"`** (per `handlers.rs::fs_seek`), not `"start"` as some FIP prose uses.
- **Rholang requires `|` between adjacent processes** inside a `for` body.  A `stdout!(...)` immediately followed by a nested `for(...)` without a separator is rejected by tree-sitter with a `(ERROR (send ...))` sexp.
- **Sequential-lock intra-testSuite serialization**: two testSuite entries that each `openFile("target")` + `lines()` on the same bundled path RACE for a same-path sequential lock with distinct holders — first-in acquires, second BLOCKS forever unless the first explicitly `close()`s the stream.  If a test's assertion fires from a non-close-taking path (e.g., a default-arm error branch), the lock leaks and blocks the next testSuite entry.  **Fix pattern**: combine related dispatches into ONE contract using ONE lineStream, not two testSuite entries.
- **RhoSpec anti-vacuity error `"missing genesis/registry state"`** with `has_finished=false` typically indicates a hung deploy inside RhoSpec's tokio timeout window (often the sequential-lock leak above).
- **Em-dashes / apostrophes / backticks in Rholang string literals** break tree-sitter parsing (UNEXPECTED 8212 for em-dash).  Use ASCII dashes and standard punctuation in `!?("...", ...)` string args and assertion clues.
- **RhoSpec harness cannot drive wait:true admits**: cross-cap `wait:true` lockRange deploys time out silently rather than resolving parked acquires (harness doesn't drive the tokio waker infrastructure).  Use wait:false + explicit retry for cross-cap E2E; strict FIFO is unit-tested at LockRegistry layer.  Recorded in `~/.claude/projects/-Users-stay-greg-f1r3fly-FIPS-fileio/memory/fileio_wait_true_e2e_harness_gap.md`.

### fs_lock CRIT-2 backport reference (commit `34b8f1d1`)

Kept as a class-of-bug reference: any fd-consuming native written before Slice 28's `seed_next_fd_from_state_hash` landed can carry a stale `if fd >= 0` guard that rejects hash-derived u64 fds whose high bit is set.  Symptom: ~50% flake rate on real-bundle openFile-then-anything, invisible under mocked tests that use small fd values.  Fix pattern: reinterpret via `fd as u64` (mirrors `fs_close` at `handlers.rs:600`).  Regression pin lives in `fileio_examples_spec::fileio_lockrange_cross_cap_busy_then_release`.

### Phase 10 remaining slice-level checklist

**Canonical examples (10a-1 .. 10a-9)** — all landed prior session (see commit table above).

- [x] 10a-1 through 10a-9 — canonical examples

**Per-error-code coverage (10b)** — landed:

- [x] 10b — per-error-code integration test — `fileio_error_matrix_spec.rs`, 12 tests covering FSERR_BAD_ARG (3) / FSERR_UNSUPPORTED (3) / FSERR_CLOSED (2) / FSERR_BUSY / FSERR_ALREADY_EXISTS / FSERR_QUOTA_EXCEEDED / FSERR_BAD_ARG-on-dir-kind.  Discovery of the io-error-kind loss bug lived here → `fix(fileio) slice 10b` (`bf254f951`) landed the routing fix through `quarantine_err_reply → io_err_code`; companion FIPS path-leakage pin (`63f78064a`) guards `io_msg_scrub` from `to_string()` regressions.

**Stdio replay wiring (10c)** — reclassified out of the roadmap:

- [x] ~~10c — stdio replay wiring~~ **RECLASSIFIED 2026-08-23 as not needed**: stdio is intrinsically oracular; enforced by Stdin.rho / Stdout.rho constructor signatures + pinned by `stdio_agents_have_no_cmode_arg_and_stay_oracular`.  Deploy-author responsibility: don't route stdin bytes into consensus-observable state.  Rationale docstrings in Stdin.rho / Stdout.rho / Fs.rho; commit `5d98daa21`.

**Replay-harness-dependent slices (10d, 10e)** — still blocked:

- [ ] 10d — oracular replay E2E for examples (needs two-runtime replay harness)
- [ ] 10e — `fileio_cross_fs_isolation.rho` (Powerbox stub blocked)

**Review-pass E2E gap-fills (10g-10j)** — landed prior session (see commit table above):

- [x] 10g — `fileio_stream_spec.rs` (LineStream negative-path matrix, 4 tests)
- [x] 10h — `fileio_file_spec.rs` (File-agent method E2E, 4 tests)
- [x] 10i — `fileio_consensus_replay_spec.rs` (stat host-transient field omission, 2 tests; Layer 2 leader-follower replay blocked on harness)
- [x] 10j — `fileio_dir_spec.rs` bootstrap (Dir.exists / openFile mode attenuation / openFile→readN, 3 tests)

**Phase-10 additional coverage (2026-08-23 session)** — landed:

- [x] Dir mutations E2E — extension of `fileio_dir_spec.rs` with 4 mutation round-trips (removeFile / removeDir(recursive) / rename / copyFile) verified via on-disk `std::fs` reads.
- [x] 3-way lockRange no-starvation E2E — `fileio_examples_spec::fileio_lockrange_three_way_no_starvation`; uses wait:false + retry chain (wait:true 3-way is blocked on RhoSpec harness plumbing, recorded in project memory).
- [x] `fileio_lifecycle_spec.rs` — fd-table rollback via production `create_soft_checkpoint` / `revert_to_soft_checkpoint` path (2 tests, including nested-checkpoint stack semantics).
- [x] `fileio_fs_spec.rs` — Fs / Stdin / Stdout surface coverage (6 tests including default-mode inference and the `r+` mode drift pin surfaced during writing).
- [ ] `fileio_native_spec.rs` — direct RhoSpec dispatch of each native URN.  **Deferred** (low priority per plan): natives are unit-tested + reached transitively; needs genesis-scope URN-filter toggle in test source.

**Cross-phase slices landed alongside Phase 10:**

- [x] Slice 9b-iv follow-up — `fs_entries` per-entry two-branch charge (leader + replay), with 5 unit-test parity pins for `extract_ok_list_len`.  Deferred blockers documented for `fs_entries_stream` (stub) and `fs_remove_dir` (reply-shape change needed).  Commits `fad068ffd` + `2d065cf68`.
- [x] Slice 9c-ii — Buffer materialization cap: `toByteArray()` → `toByteArray(@cap)` with FSERR_QUOTA_EXCEEDED gate, 4 File.rho caller updates at MAX_WRITE_BYTES, 4 runtime pins covering each gate arm.  Commits `f6fe61f30` + `eae9f13ae`.

**Whole-phase review + push (10f)** — landed:

- [x] 10f — whole-Phase-10 review + push to origin.  12 commits landed on `fileio-phase-1-2` over 2026-08-23; branch tip on `origin/fileio-phase-1-2` currently `5d98daa21`.  Review passes for slices 10b, 9b-iv follow-up, and 9c-ii each produced additional regression pins.

### Hard-fork surfaces flagged during Phase 10 (for eventual master merge)

The following code changes have consensus-relevant semantics.  All safe on the pre-production `fileio-phase-1-2` branch; require merge-coordination when master-bound.

- **io-error-kind widening** (`bf254f951`): `map_open_err` in `path.rs` now preserves `io::ErrorKind` and `quarantine_err_reply` routes AlreadyExists / NotFound / PermissionDenied / Unsupported / InvalidInput to their spec-canonical FSERR codes instead of collapsing to FSERR_IO.  Reply tuples reach the tuplespace; different code = different state hash.
- **fs_entries per-entry supplement** (`fad068ffd`): realized cost under D3 changes from `50` to `50 + 32*n_entries` per fs_entries call.  Directly hard-forkable.
- **Genesis-source anchor rolls**: `126a35ab → fbea2d02` (slice 9c-ii, `f6fe61f30`), `fbea2d02 → af6f10fa` (10c reclassification docstrings, `5d98daa21`), `af6f10fa → cd2f6494` (PB-B-3 initial wiring), and `cd2f6494 → 46db7011` (PB-B-3 final ship with docstring cleanup + await sequencing).  All change the fs-genesis-deploy content hash.
- **PB-B-3 insertVersion call** (2026-08-24): FsGenesis now emits an `insertVersion` message onto `rho:registry:v1:internal` for the fs cap.  Adds a new tuplespace effect to the fs-genesis deploy's execution trace; historical blocks without this effect would fail replay.
- **Streaming-backing slice Step 2** (`d70ca8235`, 2026-08-25): three new native URNs registered — `rho:io:fs:native:1.0.0/entriesStreamOpen` (arity 4), `.../entriesStreamNext` (arity 2), `.../entriesStreamClose` (arity 2).  Composed FsGenesis source gains three new native bindings.  `non_deterministic_ops()` gains three replay-cache entries.  Deploy-content hash rolls from `46db7011` → `434a828b`.  Native URNs remain under the `FS_NATIVE_URN_PREFIX` filter — user deploys cannot resolve them directly; the composed Fs agent captures them lexically for the Dir.rho consumer swap (Step 5).
- **Streaming-backing slice Step 3** (`ac7bb9b6a`, 2026-08-25): new `WalOp::EntriesStreamNext` variant (op_tag = 15) journaled per `entriesStreamNext` call on Consensus-cap dir streams.  `SNAPSHOT_FORMAT_VERSION` bumped 3 → 4 (WAL root encoding hard-fork).  Golden `compute_wal_root_golden_hex` rolled forward `9f2553c3` → `0db9a418`.  Follower shadow-handle insertion (Step 2's `entriesStreamOpen` replay branch) is the load-bearing dependency for byte-identical WAL entries across leader/follower — verified by the new `entries_stream_next_wal_is_byte_identical_on_leader_and_follower` pin.  Consensus-committing per-call journal on a streaming primitive is novel for this branch; joining validators fetching snapshots past this commit must understand the v4 layout.
- **Streaming-backing slice Step 5** (2026-08-25): `Dir.rho::entries()` body swapped from bulk `fsEntries` list-materialization to `entriesStreamOpen`/`Next`/`Close` pull model.  Composed FsGenesis source `compose_fs_genesis_source_golden_hex` rolled forward `434a828b` → `60035818`.  Under Consensus caps, each `entries()` deploy now emits a stream of `WalOp::EntriesStreamNext` entries (one per yielded record, plus one on EOS) instead of a single `WalOp::EntriesRead` — different WAL shape, different state hash on any block containing a Consensus-cap `Dir.entries()` call.  Same caller-facing Stream API; the bulk `fsEntries` native is unchanged and remains dispatchable from outside Dir.rho.
- **Streaming-slice Step 5 review-fixup A** (`b7f04dd74`, 2026-08-26): composed FsGenesis source `compose_fs_genesis_source_golden_hex` rolled forward `60035818` → `5efce8f422d240b2e271fd7407d0a80e6c2a62302195fb8cce42c13dabf00c5e`.  Producer-wrapper malformed-arm now closes the stream fd before responding FSERR_IO (defense-in-depth; arm currently unreachable).  Docstring correction for the fd-sweep story.  Only observable code change: the malformed-arm close (unreachable today).
- **Cost-helper audit** (`d0df35476`, 2026-08-26): switches bulk `fs_entries` handler (both branches) plus four sibling length-parameterized handlers (`fs_read`, `fs_read_at`, `fs_write`, `fs_write_at`) from `reserve_primitive` to `reserve_incremental_primitive`.  Pre-fix, an empty-dir `fs_entries` call on a Consensus cap hit `BugFoundError` inside `reserve_primitive(0)`, populated `EvaluateResult.errors`, and skipped the WAL journal that would fire after the supplement.  Post-fix, the deploy runs to completion and journals.  Hard-forkable: any historical block containing an empty-dir Consensus `fs_entries` would replay differently.  The four sibling handlers are consensus-safe under today's inputs (`FS_SYSCALL_CONST = 100` base keeps cost > 0); the switch is defense-in-depth against a future coefficient change.
- **Phase 8 review follow-up cursor-relative TOCTOU docstring** (`e578ae9dd`, 2026-08-26): composed FsGenesis source `compose_fs_genesis_source_golden_hex` rolled forward `5efce8f4…` → `1f3e8878df25f6845619ef2e8e2450aa99e836312652bf701dccbcd15a1f3787`.  File.rho::readInto gains a new documentation section.  Comment-only; no on-wire semantics change.
- **WAL sequential-Write/Read offset population** (position-follow-up, 2026-08-26, pending commit): `WalEntry.offset` for `WalOp::Write` and `WalOp::Read` (sequential ops, not the `_at` variants) changes from `None` to `Some(pos)` where `pos` is the fd's pre-op shadow position pulled from a new `FileHandle::position` field.  Consequence: WAL root changes for every block containing a Consensus-cap `fs_write` or `fs_read` (sequential).  Also: Consensus caps with `O_APPEND` open modes (`a` / `a+`) now return `FSERR_BAD_ARG` at `fs_open` — historical blocks that used these combinations would replay with different reply tuples.  `SNAPSHOT_FORMAT_VERSION` is NOT bumped — the encoding schema is unchanged (`encode_opt_u64(Some(pos))` is 9 bytes vs `encode_opt_u64(None)` = 1 byte, but both are valid v4 encodings).  The change is purely in the CONTENT of entries the handlers emit.  Golden hex test `compute_wal_root_golden_hex` uses a hand-built `Write` entry with `offset: Some(0)` which happens to match the new post-fix encoding for a fresh fd's first write, so no golden roll is required.  Landed to close the file-state-identity gap surfaced during Path A(ii) (see Deferred items catalog entry).
- **Phase 7b-2 review-fixes — cap sync, admit reorder, blacklist TTL** (`bc30dd1ce`, 2026-08-27).  Six review findings landed in one slice on top of the just-shipped `679f9cea8`.  **F-1 (correctness):** `MAX_PAYLOAD_BYTES` was 4 MiB but the handler-level `MAX_WRITE_BYTES` / `MAX_READ_BYTES` cap is 64 MiB — legit large writes were rejected as PayloadOversized AND blacklisted the honest peer.  Raised to 64 MiB; new T-9 pin (`max_payload_bytes_matches_handler_write_cap`) asserts equality with both handler caps so drift surfaces as a test failure.  **F-2 (runtime):** `InMemoryPayloadStore::get` did `.blocking_read()` on a `tokio::sync::RwLock` from inside an async context — documented tokio footgun that blocks the executor thread.  Swapped to `std::sync::RwLock`; guard never held across `.await`.  Three insert-callers updated (no more `.await`).  **F-3 + F-5 (DoS + performance):** `admit_response` hashed BEFORE checking the pending set, so unsolicited flood packets each burned a Blake2b256 (~200ms for 64 MiB) before rejection; broadcast HasWalPayloadRequest lets attackers enumerate our pending hashes.  Reordered — cheap pending-lookup first, then hash + hash-compare only if we care.  Race-safe: read-check pending → hash → write-check-and-install with a re-check.  Two new pins (`unsolicited_response_rejected_before_hashing`, `duplicate_response_for_accepted_slot_short_circuits_before_hashing`) use tampered bytes to prove hashing didn't run.  **F-4 (correctness):** tick's `already_in_flight` boolean returned false after `retry_count >= MAX_RETRIES`, so we kept sending past the cap.  Replaced with three-state `TickAction { SendFresh, WaitInFlight, GiveUp }` enum; GiveUp logs at debug and stops sending.  **F-6 (fairness):** `blacklisted` was `HashSet<PeerNode>` with no eviction — legit peers with transient failures got killed for process lifetime.  Changed to `HashMap<PeerNode, u64>` (peer → blacklist timestamp) with `BLACKLIST_TTL_MS = 1 hour`; new `evict_expired_blacklist` runs every tick (which now runs unconditionally, not only on non-empty pending set, so eviction happens even when idle).  `next_source_for` treats expired-TTL entries as eligible so peers rejoin the pool immediately.  **Test additions:** T-1 wire handler tests (+5) with a minimal `CapturingTransport` mock — serves-known-hash, silent-on-unknown, silent-on-malformed for both Get/Has request handlers; T-7 DirectoryPayloadStore IO error paths (+2) including Unix-only chmod-0o000 permission-denied surface; T-11 empty-payload accept; F-6 pins (+3).  Test posture: wal_payload_* 41/41 (+15 from review), snapshot_chunk_* 28/28 regression, casper lib 663/663.  **Not addressed** (deferred): T-6 (Running::handle context-absent dispatch) needs Running scaffolding beyond scope; T-4 (install-once OnceLock semantics) is stdlib-guaranteed.
- **Phase 7b-2 between-snapshot WAL payload fetch protocol** (`679f9cea8`, 2026-08-27).  Consumer + server + wire + sync driver + boot integration for the `get_wal_payload(payload_hash)` opcode.  Same shape as Phase 7b-1 snapshot chunk-fetch, keyed on payload Blake2b256 hashes rather than `(block_hash, chunk_index)` pairs.  New CasperMessage variants: `GetWalPayloadRequest`, `WalPayloadResponse`, `HasWalPayloadRequest`, `HasWalPayload` with matching protobuf + ToPacket impls in `models/`.  Consumer `WalPayloadRetriever` verifies via `Blake2b256(payload_bytes) == payload_hash` — payload_hash IS its own anchor, no Merkle proof needed (unlike snapshot chunks).  Security caps: `MAX_PAYLOAD_BYTES = 4 MiB` (rejected before hashing).  Server `PayloadLookup` trait pluggable backing store with `InMemoryPayloadStore` + `DirectoryPayloadStore` reference impls (`<dir>/<hex(hash)>` shape).  `serve_payload` rehashes returned bytes as defense-in-depth.  `WalPayloadSyncDriver` mirrors `SnapshotChunkSyncDriver` but with FLAT hash-addressed namespace: single retriever + per-hash source map + GLOBAL blacklist (stronger blacklist stance than per-target — a peer producing bad bytes for one hash is likely adversarial across the board).  Security caps: `MAX_SOURCES = 256`, `MAX_BLACKLISTED = 1024`.  Boot enumerator `enumerate_and_enqueue_payloads` accepts a `is_reproducible` predicate — the write-payload-determinism reducer scaffolding (plan §377).  Running-engine dispatch adds four match arms with `OnceLock<WalPayloadContext>` field.  `transition_to_running` gains optional `wal_payload_ctx` param; three callers updated (casper_launch, initializing, genesis_ceremony_master) each construct an in-memory-backed context.  Follow-ups (not blocking Phase 7b-2 as shipped): (a) populate a `DirectoryPayloadStore` as fs_write handlers journal payloads; (b) wire the write-payload-determinism reducer so the joiner skips fetching bytes it can reproduce locally.  Test posture: 26/26 wal_payload_*, 28/28 snapshot_chunk_* (regression), 648/648 casper lib, 59/59 models lib, 285/285 rholang io lib, 54/54 fs_wal_spec.
- **Phase 7b-1 Merkle chunker for snapshot fetch** (`689bdc1fa`, 2026-08-27).  First deliverable of Phase 7b (byte-payload distribution).  New `rholang/src/rust/interpreter/io/snapshot_chunk.rs` provides pure-utility Merkle chunker + inclusion-proof primitives that the follow-up network-layer `SnapshotChunkRetriever` will consume.  `chunk_snapshot` splits at 4 MiB boundaries; `snapshot_merkle_root` builds a binary Merkle tree with odd-tail promotion (Bitcoin/Ethereum-style, no duplicate-and-hash); `build_merkle_proof` / `verify_merkle_proof` provide O(log N) inclusion proofs so joiners can accept partial progress (per-chunk verification against the anchored root).  Empty-snapshot sentinel `EMPTY_SNAPSHOT_ROOT = [0u8; 32]`.  Hard-fork surfaces pinned by `chunk_size_pinned_at_4_mib` + `merkle_tree_shape_pinned_by_golden_hex` (golden root `3c1774e008c318cf17839e244d9e83bd430aa05f56d666e13caa3f83b7a50b05` over a 4-chunk deterministic input).  Follow-up scope: (a) wire the Merkle root into `WalSnapshotWrite` (currently commits `Blake2b256(bytes)` which is atomic-only; joiners need Merkle root for per-chunk verify — hard-fork surface); (b) `SnapshotChunkRetriever` mirroring `BlockRetriever`'s RequestState/timeout/retry/peer-set shape; (c) two new wire opcodes (`get_snapshot_chunk` request/response + broadcast variants).
- **fs_remove_dir per-entry cost supplement** (`114a36c73`, 2026-08-27).  Closes the Phase 9 "fs_remove_dir two-branch charge" open item.  Post-H-29-3-lift the recursive Consensus reply carries a manifest, so both leader and follower derive the deletion count deterministically (leader from walk, follower from `extract_removedir_manifest(previous)`).  Non-recursive: supplement = 1; Consensus recursive: supplement = manifest length; Oracular recursive: supplement = 0 (no wire-visible count — accepted as Oracular-scope pricing choice).  Cost hard-fork surface: non-recursive removeDir goes 200 → 232, Consensus recursive 200 → 200 + 32n.  Two new runtime pins in `fileio_cost_runtime_spec.rs`.
- **H-29-3 lift — path-based Consensus mutations wire WAL journaling** (`7040faf71` + `bd14d8bbb`, 2026-08-26).  All six path-based mutations (`fs_chmod`, `fs_chown`, `fs_rename`, `fs_copy_file`, `fs_remove_file`, `fs_remove_dir`) previously returned `FSERR_UNSUPPORTED` on Consensus caps as an interim stopgap ("WAL journaling for path-based mutations not implemented").  Post-lift, all six succeed on Consensus and journal a corresponding WAL entry pre-syscall.  Slice-1 handled the five 1-op semantics handlers (single WAL entry fully derivable from args); slice-2 handled `fs_remove_dir` including recursive with granular sorted-post-order manifest packed into the reply for symmetric follower replay.  Consensus impact: (a) every block containing a Consensus-cap invocation of these ops (previously returning `FSERR_UNSUPPORTED`) now returns success with new WAL entries; (b) recursive Consensus removeDir reply shape gains `[true, [[path, kind], ...]]` (uniformly asymmetric — non-recursive Consensus and Oracular replies unchanged); (c) fs_genesis composed-source anchor rolls `1e6c53b8` → `91adaac8` → `e172310924b99c112af1c9c8d332a6d4a325e514d67eb65c26c1dcebb7749ac7` across the two slices (Dir.rho + File.rho source edits).  `SNAPSHOT_FORMAT_VERSION` not bumped — the `WalOp` variants (Chmod/Chown/RemoveFile/RemoveDir/Rename/CopyFile) were already reserved at their tag slots in v4.  Rholang callers of Dir.rho methods see the same reply shape unless they wrote code specifically against Consensus recursive removeDir (which was FSERR_UNSUPPORTED pre-lift, so no live callers).  WAL audit now clean across all currently-emittable variants — see the plan-doc audit summary from 2026-08-26.

## Deferred items catalog

Open items with their blockers.  A fresh session should skim this first — most "what's next?" questions resolve here.

### Unblocked next-step candidates (2026-08-27 survey)

Snapshot as of `bc30dd1ce` (Phase 7b-2 review-fixes landed).  Each item is start-anytime; open design decisions are consolidated in `design-decisions.md` (sibling doc).

**Phase 7b-2 follow-ups (natural next after network-layer landed):**

- ~~**(a) Wire the write-payload-determinism reducer.**~~ **SIGNATURE LANDED, WIRING DEFERRED TO ITEM (c).**  `enumerate_and_enqueue_payloads` refactored to DD-7b-2 (a) committed signature: `FnMut(&WalEntry) -> Option<Vec<u8>>`.  Reducer returns `Some(bytes)` to skip peer fetch (bytes handed to retriever via new `WalPayloadRetriever::mark_resolved`) or `None` to enqueue for fetch.  Defense-in-depth rehash on `mark_resolved` catches reducer bugs (debug-build: `debug_assert!` panics; release-build: returns `false`, enumerator logs `info` + falls back to peer fetch).  Return type is now `EnumerateStats { resolved_locally, enqueued_for_fetch }` for observability.  No production caller yet (that's item (c)) — for now, callers pass `|_| None`.  Test posture: `wal_payload_sync` 46/46 (+5: `enumerate_and_enqueue_fetch_everything_reducer`, `enumerate_and_enqueue_full_reducer_coverage_needs_no_fetch`, `enumerate_and_enqueue_reducer_returning_wrong_bytes_falls_back_to_fetch` (release-only), `mark_resolved_accepts_valid_reducer_output`, `mark_resolved_is_idempotent_on_already_resolved`, `mark_resolved_rejects_mismatched_bytes` (release-only), `mark_resolved_debug_asserts_on_mismatched_bytes` (debug-only)).

- ~~**(b) Populate a `DirectoryPayloadStore` on the serving side.**~~ **LANDED** `4b1c19102` (2026-08-27).  New `PayloadPersistence` trait in `rholang/io/wal.rs`; `FileHandleTable.payload_store` interior-mutable slot (`Arc<std::sync::RwLock<Option<Arc<dyn PayloadPersistence>>>>`) so post-spawn shares reach the `FsProcesses` clone taken at reducer-setup time; `journal_write` + `finalize_write_journal` call `store.persist(bytes)` on Consensus caps with log-and-continue on `Err`.  `PayloadStoreBundle` (casper) bridges the split-crate `PayloadPersistence` (rholang) + `PayloadLookup` (casper) traits — same underlying store reached through two Arc-typed clones.  `RuntimeManager.payload_store: Arc<tokio::sync::RwLock<Option<PayloadStoreBundle>>>` mirrors `fs_snapshot_writer`.  `setup.rs` installs a `DirectoryPayloadStore` at `<data-dir>/wal_payload_store/` (DD-7b-1 (a)); all three boot sites (`casper_launch`, `initializing`, `genesis_ceremony_master`) now read `runtime_manager.get_payload_store()` for `WalPayloadContext.payload_lookup`.  Pins: `payload_store_wiring_tests` (6 tests in runtime_manager.rs) + 4 E2E tests in `fs_wal_spec.rs` (consensus persists, oracular does not, absent-store still journals, persist-Err does not abort deploy) + source-scan `boot_pipeline_installs_payload_store` in snapshot_config.rs.

- ~~**Retention pass (DD-7b-1 (y)).**~~ **LANDED** `4b54de853` (2026-08-27).  Sidecar-based: `write_snapshot` writes a `<hex(root)>.hashes` file alongside each `.wal` (format `[u32-be count][32-byte hash × count]`).  `prune_snapshot_dir` also removes `.hashes` siblings.  New `scan_retained_payload_hashes(snapshot_dir)` unions all sidecars.  New `prune_payload_store(payload_dir, keep)` deletes any 64-char-hex-decode-valid filename not in the keep set; skips symlinks and non-hex names for defense.  Finalization runner's `WalSnapshotWrite` branch chains `spawn_blocking(scan_retained_payload_hashes → prune_payload_store)` after each successful `maybe_write`.  Corrupt sidecars → over-eager prune (safe direction — joiner re-fetches from peers).  `SnapshotWriter` gained an optional `payload_dir: Option<PathBuf>` field; `build_snapshot_writer` gained a matching parameter; `setup.rs` plumbs `data_dir_snapshot.join("wal_payload_store")` through.  Pins: 6 snapshot-side (referenced_payload_hashes dedup + Hash-only filter, sidecar round trip, corrupt-sidecar-as-empty, `write_snapshot` writes sidecar, `scan_retained_payload_hashes` union across snapshots + skips non-`.hashes` files, `prune_snapshot_dir` removes siblings) + 4 payload-side (remove non-retained, ignore non-hex names, missing dir → Ok(0), skip symlinks).  Not landed: end-to-end integration test showing the three-way chain via finalization runner (item (c) will exercise).

- **(c) Wire the boot enumerator + apply-to-follower path.**  `enumerate_and_enqueue_payloads` isn't called from any production site.  Need a caller in `casper_launch` / `initializing` after snapshot fetch completes; on retriever `is_complete()`, collected bytes need to be applied via the fresh-tree WAL applier (helper `apply_wal_to_fresh_tree` lives in `fs_wal_spec` test module — must move to a production location).  Depends on design decision **DD-7b-3** (sync completion signal).

- **(d) Two-validator PB-M-14 E2E.**  Byte-transport now ready; still needs `TestNode` retrofit for shared FS root + in-process TransportLayer stub.  Bounded scaffolding (~200-300 LOC of harness + ~50 LOC test).  See interim-coverage note in "Phase 7 open items" below for what's already pinned.

**Pre-existing unblocked (unchanged from prior surveys):**

- **Native arity tightening** — retire the legacy arity-7/4 shim.  ~300 test caller migrations across `rholang/tests/`; mechanical.  No design.
- **Randomized tokio-schedule stress test** — property-test the fs handlers under `#[tokio::test(flavor = "multi_thread")]` with `yield_now` inserted at await points.  Catches ordering bugs the deterministic tests miss.
- **Dir-stream fd deploy-end sweep** (implementation bounded; has design call **DD-Dir**).  See "Phase 9 open items" below for the leak-visibility pin.

**Blocked (not currently actionable — kept here for cross-reference):**

- Phase 10e `fileio_cross_fs_isolation.rho` — blocked on Powerbox stub.
- `fileio_buffer_spec.rs` — blocked on PB-B-5 (Allocator not published to user deploys).
- 9c-iii Buffer pairwise-merge test — blocked on Buffer.rho refactor itself.
- `foldConcurrent` / `mapReduce` positive-path tests — blocked on those methods landing in Stream.rho.
- `Produce::with_error` for cancellation replies — blocked on reporting-rspace.

### Historical open items (organized by phase)

**Phase 7 open items:**

- **Two-validator PB-M-14 end-to-end test** — needs `TestNode` + `GenesisBuilder` per-node consensus-static HOCON wiring; ~200-300 LOC test once harness confirmed.  **Interim coverage landed 2026-08-26** (`7630b00de`): `fs_wal_spec::multi_deploy_wal_is_byte_identical_on_leader_and_follower` extends the single-deploy byte-identity pin to a 3-deploy sequence with mixed Consensus + Oracular caps; verifies the WAL-byte-identity half of PB-M-14.  Scaffold test `fs_wal_spec::pb_m_14_two_validator_scaffold` (ignored) documents the specific `TestNode` / `GenesisBuilder` gaps and the assertion shape needed.  **FILE-STATE-IDENTITY half landed 2026-08-26** (Path A(ii), pending commit): `fs_wal_spec::pb_m_14_file_state_identity_via_wal_replay` + `wal_applier_skips_failure_outcome_entries` add a fresh-tree WAL applier (`apply_wal_to_fresh_tree`) that reconstructs on-disk file state on an empty follower tree using ONLY the WAL slice + a Phase-7b-style payload sidecar (hash → bytes).  Test drives a 3-deploy Consensus `fsWriteAt`/`fsTruncate` sequence on the leader, applies the resulting WAL to a fresh follower tree, and asserts byte-identical tree contents.  Restricted to `WriteAt`/`Truncate` for now — see new deferred entry "WAL fresh-tree applier: sequential-Write reconstruction" below.  Fully-remaining gap for the two-validator E2E test is Casper block-processing propagation (Path B: TestNode fs provisioning + observation hooks).
- ~~**WAL fresh-tree applier: sequential-`Write` reconstruction**~~ **LANDED 2026-08-26** (position-follow-up, pending commit).  Path (b) chosen: `FileHandle` gains a `position: u64` shadow field; `journal_write` / `journal_read` now populate `offset` for sequential ops from the shadow position (which both leader and follower evolve deterministically from the same sequence of contract-arg values + reply values).  `fs_seek` syncs shadow position on both branches.  Consensus + `O_APPEND` open modes (`a` / `a+`) rejected at `fs_open` — the shadow-position model doesn't fit kernel-atomic append semantics without per-canon_path EOF simulation, tracked as a future-slice possibility.  Applier's sequential-`Write` panic removed; `Write` now handled identically to `WriteAt` (both carry absolute offset).  New pins: `fs_wal_spec::pb_m_14_file_state_identity_sequential_write`, `wal_position_stays_in_sync_on_leader_and_follower`, `consensus_append_open_is_rejected`.  Hard-fork surface: every block containing a Consensus-cap `fs_write` or `fs_read` (sequential, not `_at`) now records a different WAL entry (offset field went from `None` to `Some(pos)`) — WAL root changes for those blocks.  See new hard-fork surfaces catalog entry.
- **Phase 7b — byte-payload distribution protocol** — snapshot chunk-fetch (`get_snapshot_chunk`, 4 MiB Merkle chunks) + between-snapshot on-demand fetch (`get_wal_payload`).  Extends existing Casper block-fetch machinery.  **Infrastructure survey (2026-08-26):** no existing scaffolding.  `BlockRetriever` at `casper/src/rust/engine/block_retriever.rs:79` (~300 LOC) is the extension template — Phase 7b needs two parallel retrievers (`SnapshotChunkRetriever`, `WalPayloadRetriever`), each with its own `RequestState` map, timeout/retry logic, peer-set tracking.  Message-protocol additions: two new opcodes in the Casper wire protocol (`get_snapshot_chunk` request/response + `get_wal_payload` request/response, plus their broadcast variants).  Merkle-chunker: split snapshot into 4 MiB pieces, compute per-chunk Blake2b256 hashes, root = Merkle root over hashes (PB-M-15 already commits snapshot root on-chain via `record_finalization_effect(..., WalSnapshotWrite)` post-2026-08-26).  Estimate: multi-session, 3-5 files across `casper::engine`, `models`, `comm`.  Design memo: implementation-plan.md:374-377 (Option C).
- **Powerbox stub** — interim per-`deployerId` Powerbox listed as Phase 6 deliverable; not built (shipped shared-Fs MVP).  Dedicated slice.  When landed, revisit Phase 10 `fileio_cross_fs_isolation.rho` + `fileio_membrane.rho` examples.

**Phase 9 open items** (see §Phase 9 delivered):

- **9c-iii Buffer pairwise-merge growth test** — blocked on the refactor itself (Buffer.rho line 16 uses Θ(ℓν) linear-fold; test would assert Θ(ℓ log ν)).
- **`fs_entries_stream` streaming backing** — ~~the URN + dispatcher are wired (`rho:io:fs:native:1.0.0/entriesStream`, `handlers.rs:2449`), but the handler body unconditionally returns `[false, FSERR_UNSUPPORTED, "entriesStream backing not yet implemented (Phase 1 tail-end)"]`~~ **LANDED 2026-08-25/2026-08-26** as three arity-2/4 natives (`entriesStreamOpen` / `_next` / `_close`) via the streaming-backing slice (Steps 1-8 + review-fixups A/B; final head `5c9b18dbd`).  The original arity-3 `fs_entries_stream` handler at `handlers.rs:2449` remains as an FSERR_UNSUPPORTED stub for URN backward-compatibility but is unreachable from any post-Step-5 production caller (Dir.rho::entries() now dispatches to the new natives).  Deprecated-stub state pinned by `fileio_cost_spec::arity3_entries_stream_stub_still_returns_fserr_unsupported`.
- **Dir-stream fd deploy-end sweep** — `DirHandleTable::close_all_for_deploy` exists at `rholang/src/rust/interpreter/io/dir_handle_table.rs:356` and mirrors `lock_registry.release_all_for_deploy`'s API shape, but is NOT wired into `WalDeployScope::Drop` (surfaced during the Steps 4-8 review pass — the Step 5 commit body originally claimed the sweep was wired; corrected in fixup `b7f04dd74`).  Consequence: a Rholang deploy that opens Dir.entries() streams and drops the Stream cap before EOS (via `Stream.close()` or by dropping the reference) holds dir fds until the runtime is dropped.  Current mitigations: (a) per-runtime `MAX_OPEN_FDS = 1024` cap; (b) per-block runtime respawn via `RuntimeManager::spawn_runtime` cleans state between blocks.  Under adversarial Rholang, an attacker can pin all 1024 dir fds within one block and DoS subsequent dir-list operations within the same runtime lifetime.  Fix scope: wire `dir_handles.close_all_for_deploy(scope)` into `WalDeployScope::Drop` (uses existing `DirHandle.deploy: DeployScope` field, sentinel-scope guard already in place).  Async-in-sync-Drop needs care — the lock sweep is sync; dir table sweep would need `Handle::current().block_on(...)` or similar.  Design consistency: `FileHandleTable` also lacks a deploy-end sweep — either wire both together or accept both under the same mitigation contract.  Leak-visibility documented by `fileio_stream_spec::open_without_close_leaves_fd_in_table`.
- ~~**fs_remove_dir two-branch charge**~~ **LANDED** (`114a36c73`, 2026-08-27).  Post-H-29-3-lift the recursive Consensus reply carries a manifest, unblocking symmetric two-branch charge derivation.  Non-recursive supplement = 1; Consensus recursive = manifest length; Oracular recursive = 0 (accepted asymmetry; both sides derive from args-visible cmode + recursive).  Two runtime pins added.
- ~~**bulk `fs_entries` `reserve_primitive(0)` bug on empty dirs**~~ **LANDED** (`d0df35476`, 2026-08-26).  Bulk `fs_entries` (both branches) switched to `reserve_incremental_primitive`; four sibling handlers (`fs_read`, `fs_read_at`, `fs_write`, `fs_write_at`) also brought into conformance per the discipline docstring at `costs.rs:43-49`.  Source-scan pin `length_parameterized_cost_helpers_use_reserve_incremental_primitive` prohibits `reserve_primitive(costs::<helper>` for the six length-parameterized helpers.  Empty-dir runtime pin strengthened with `result.errors.is_empty()` assertion.  See Hard-fork surfaces section above.

**Phase 10 open items** (see checklist above):

- ~~**10d** oracular replay E2E~~ **LANDED** (`8cfddd1ee`, 2026-08-27).  `fileio_replay_spec.rs` — 4 tests via `create_leader_and_follower`: multi-deploy Oracular workload, mixed Oracular + Consensus workload, Oracular path mutations (copyFile/chmod/rename/removeFile), Oracular recursive removeDir.  All replay cleanly via `check_replay_data`.
- **10e** `fileio_cross_fs_isolation.rho` — blocked on Powerbox stub.
- ~~**`fileio_native_spec.rs`**~~ **LANDED** (`3f0241149`, 2026-08-27).  23 per-URN dispatch smoke checks via the `disable_fs_native_urn_filter` genesis-scope helper.  Pins the wiring (URN → native handler) survives future H-29-3 lifts / streaming-slice reshuffles.
- **`fileio_buffer_spec.rs`** — blocked on PB-B-5 (Allocator not published to user deploys).
- **`foldConcurrent` / `mapReduce` positive-path tests** — blocked on those methods landing in Stream.rho (line 23: "Deferred to follow-up commits").
- ~~**Layer 2 consensus replay**~~ **LANDED** via `fs_wal_spec::multi_deploy_wal_is_byte_identical_on_leader_and_follower` (2026-08-26) + companion pins.
- ~~**`fileio_replay_spec.rs`**~~ **LANDED** — same commit as 10d oracular replay E2E (`8cfddd1ee`).

**Phase 8 non-blocking review follow-ups** (documented in §Phase 8 delivered):

- MAX_WAITERS_PER_FILE cap (NB-3) — deferred: hard-fork surface (rejection code path change), needs threshold decision.
- Cross-deploy mutual-wait deadlock (NB-7) — deferred: beyond Phase 8 scope, needs design.
- Native arity tightening (retire legacy arity-7/4 shim) — deferred: standalone slice, ~300 test caller migrations.
- Produce::with_error for cancellation replies (NB-4) — blocked on reporting-rspace.
- ~~LockRegistry Drop-trait test (N4)~~ **LANDED** `e578ae9dd` (2026-08-26).  Pin `lock::tests::registry_drop_surfaces_recverror_to_parked_waiter`.
- ~~helper-binding drift source-scan pin (F-2)~~ **LANDED** `e578ae9dd` (2026-08-26).  Pin `fs_genesis::tests::every_lib_top_level_helper_is_bound_in_composed_outer_new`.
- ~~cursor-relative TOCTOU docstring clarification~~ **LANDED** `e578ae9dd` (2026-08-26).  New docstring section in File.rho::readInto.
- Randomized tokio-schedule stress test — deferred: property test, medium scope, unclear ROI without a specific incident driving it.
- readLineInto arity-N+1 wait-variants (spec ambiguity) — deferred: needs semantics decision.

**Phase 7 review-pass deferrals** (Cost-FIP territory or low priority; kept for reviewers reading historical review comments):

- Per-runtime fd cap DoS aggravated by fresh-mint; no per-deploy sub-cap (H-27-1, H-27-F1).
- Mint-path `fsStat` runs on every fresh open — Consensus operators must freeze `consensus-static-*` paths for full deploy lifetime (M-27-F1).
- Deploy-cost blowup: legacy code paying O(1) for repeat opens now pays O(N) (M-27-F2).
- Handle equality consensus-observable and always false for repeat opens (M-27-1, I-27-F3).
- Tuplespace state cells grow per-mint (L-27-1).
- Mutable-file `size` under Consensus — operator-invariant issue (H-26-F2).
- Signature scope docstring note (M-26-F1); NSS PII leakage under Oracular — operator hygiene (M-26-F3).
- project_bundle HashMap iteration — defense-in-depth; already pinned by determinism test (M-26-F4).
- Play/replay runtimes have separate `fs_handles` — low likelihood (H-28-F3).
- Mid-block reset ordering fragility — consensus-safe today (H-28-1).
- 32 bits of state-hash prefix exposed via fd values — no confidentiality issue (L-28-1).
- Hard checkpoint WAL snapshot (H-R2) — if a future slice introduces `revert_to_hard_checkpoint`, must snapshot/restore WAL alongside fd table.
- Block-wide WAL cap DoS — per-deploy cost accounting is a Cost FIP concern (M-R1).
- fs_open `is_replay` skips cmode validation — inherent to is_replay pattern (M-R4).

## Streaming-backing slice — concrete implementation steps (fresh-session pickup, 2026-08-25)

Turns the `fs_entries_stream` stub at `rholang/src/rust/interpreter/io/handlers.rs:2449-2482` into a working streaming primitive.  Consumer-side wrapper at `Dir.rho:127-149` swaps from list-materialization to `next(fd)`-pull.  Under consensus mode each `next` reply must be journaled + replayable byte-identically; under oracular it's best-effort.  Scope estimate: ~700 LOC + tests, ~2-3 sessions.  Not a single-slice ship.

Order matters — the D3 WAL wiring is the hardest part and should not be left for last.

**Step 1 — `DirHandleTable` (parallel to `FileHandleTable`)**.  New file `rholang/src/rust/interpreter/io/dir_handle_table.rs`.  Mirror the shape at `handle_table.rs`:
- `pub struct DirHandle { iter: Option<tokio::fs::ReadDir>, canon_path: PathBuf, cmode: ConsensusMode }` (`iter: None` for shadow handles on the follower replay branch — same `None`-means-shadow contract as `FileHandle.file`).
- `pub struct DirHandleTable { inner: Arc<Inner> }` with monotonic `next_fd: AtomicU64` seeded from state-hash (reuse `seed_next_fd_from_state_hash` pattern; see the compile-time `MAX_OPEN_FDS` assertion at `handle_table.rs:41` for the entropy-budget invariant to preserve).
- Reuse `MAX_OPEN_FDS = 1024` cap (mod.rs:68) either shared with file fds or as a separate `MAX_OPEN_DIR_FDS`.  Recommendation: shared cap unless there's a reviewer objection — one operator-visible knob.
- `snapshot_next_fd` + `truncate_to` for deploy-boundary rollback (see `runtime.rs::WalDeployScope` Drop for the file-fd rollback shape to replicate).
- `close(fd)` drops the `ReadDir`.  `close_all_for_deploy(scope)` sweeps leaked stream fds at deploy-end (mirror `lock_registry.release_all_for_deploy`).

**Step 2 — three natives (or one arity-varying native with sub-op discriminant)**.  New URNs: `rho:io:fs:native:1.0.0/entriesStreamOpen`, `/entriesStreamNext`, `/entriesStreamClose`.  Register in `rho_runtime.rs` (see the block around line 1314 for the existing `entriesStream` registration to fork).  Assign fresh `FixedChannels::fs_entries_stream_next()` etc. — bump `byte_name(NN)` numbers past 54 (system_processes.rs:294).  Handlers:
- `entriesStreamOpen(root, rel, cmode, ack) -> [true, streamFd] | [false, code, msg]`: `safe_descend` + `tokio::fs::read_dir(canon)`, allocate fd, insert into `DirHandleTable`.  Charge `fs_entries_stream_cost(0) = 50` at entry.
- `entriesStreamNext(streamFd, cmode, ack) -> [true, entryRecord] | [false, "EOS"] | [false, code, msg]`: `handles.with_mut(streamFd, |dh| dh.iter.next_entry().await)`.  On leader: emit reply, then `reserve_primitive(fs_entries_stream_per_entry_supplement_cost(1))` (already have the helper at costs.rs:308) — one entry per call, so `n=1` unless you batch-charge at close.  Batching-at-close is a valid alternative: on `Close`, charge `supplement(total_yielded)` and record the count in the handle.  Recommendation: per-call charge — simpler replay semantics, matches the mental model of pay-as-you-consume.
- `entriesStreamClose(streamFd, ack) -> [true]`: `handles.remove(streamFd)`.  No per-entry charge here if per-call was chosen.

**Step 3 — D3 WAL wiring (consensus-mode only)**.  This is the load-bearing step.  Each `entriesStreamNext` reply on a consensus-cap stream must be journaled (leader) + replayable (follower).  Model after `fs_read` / `journal_read` at handlers.rs:220-267 + slice-29's `finalize_write_journal`:
- New `WalOp::EntriesStreamNext` variant.  Payload: the entry record produced (or an EOS marker).
- Leader path: after `dh.iter.next_entry().await`, call `journal_entries_next(streamFd, entry_record, ack)` which computes `ack_channel_hash(ack)` and `Wal::append_with_ack`.
- Follower `is_replay=true` path: DO NOT call `next_entry()` on the follower's `ReadDir` (its iteration order can diverge from leader's under oracular file-system state).  Return `previous` (the cached leader reply), same as `fs_read` at handlers.rs:2472.
- Cross-deploy fd-reuse: fd IDs derive from state-hash + monotonic counter, so a leader-side stream fd and a follower-side stream fd for the "same" call site have the same numeric value under D3 (the state hash matches at the deploy boundary).  Verify by extending an existing D3 replay-parity test.

**Step 4 — snapshot/rollback integration**.  Wire `DirHandleTable::snapshot_next_fd` + `truncate_to` into the same `WalDeployScope` Drop path (or equivalent) that already rolls back file fds.  Test: deploy that opens 3 streams then throws — assert all 3 fds are closed post-drop.

**Step 5 — `Dir.rho::entries()` swap**.  Current body (Dir.rho:127-149) captures the bulk `fs_entries` list into `listState` and pops one at a time from an `entryProducer` contract.  New body: `entriesStreamOpen!(root, rel, cmode, *fdRet) | for (@fdReply <- fdRet) { ... }` — mint the Stream around `entriesStreamNext(streamFd)`.  On stream close (Stream.EOS or consumer drop), call `entriesStreamClose(streamFd)`.  Same caller-facing `Stream` API — no changes to Dir.rho callers.

**Step 6 — bump MAX_ENTRIES-via-fs_entries messaging**.  The `FSERR_QUOTA_EXCEEDED` message at handlers.rs:1691 currently says "use entriesStream for large directories" but entriesStream was a stub — now it actually works.  Message stays the same; the affordance is now real.  Consider: raise `MAX_ENTRIES` (currently `65_536`) since streams supersede the bulk-list use case?  Recommendation: leave as-is — the bulk `entries` is still a valid convenience path for small dirs and the cap protects against wire-payload blowup on a single reply.

**Step 7 — cost pin**.  Add `fs_entries_stream_streams_five_children_charges_supplement_at_runtime` to `rholang/tests/fileio_cost_runtime_spec.rs` (companion to the `fs_entries` 5-children pin).  Fixture identical (4 files + 1 subdir); assert `consumed >= fs_entries_stream_cost(0) + fs_entries_stream_per_entry_supplement_cost(5) + 5 * fs_stat_cost()`.  Upper bound: `lower_bound + 5000` (same ceiling as the bulk pin — stream traversal shouldn't be dramatically more expensive per row).

**Step 8 — remove the source-scan pin escape hatch**.  `fileio_cost_spec.rs::entries_stream_and_remove_dir_charge_setup_only_pending_blocker_resolution` currently documents "no per-entry supplement wired, and that's OK because handler is a stub."  Once streaming lands and the supplement fires, this pin flips.  Either delete it (subsumed by the runtime pin) or narrow it to `fs_remove_dir` only (which is still blocked on the reply-shape change).

**Blockers / prerequisites**: none — all substrate exists.  `FileHandleTable`, `WalDeployScope`, `journal_*` helpers, `ack_channel_hash`, `saturate_linear`, `fs_entries_stream_per_entry_supplement_cost`, `seed_next_fd_from_state_hash` are all in-tree.  D3 cost-accounted-rho already merged.  This is scaffold-copy + wiring, not novel design.

**Hard-fork surface**: yes.  Changes the fs-genesis-deploy content hash (new URNs added to `non_deterministic_ops()`).  Adds new tuplespace effects to consensus-mode deploys (WAL entries).  Historical blocks without these effects would fail replay.  Same care as PB-B-3 / io-error-kind widening — safe on `fileio-phase-1-2`, coordinate on master merge.

### Streaming-backing slice — Steps 1-8 landed + review-fixups A/B (2026-08-26)

**Slice complete.** Steps 4/5/7/8 landed in one fresh-session pass on
`fileio-phase-1-2`, followed by two review-fixup commits (six commits
total, not yet pushed at this snapshot):

- `b49ca37db` Step 4 — dir-fd rollback via new `dir_fs_snapshot_stack`
  in `RhoRuntimeImpl`; drops the `#[ignore]` on
  `fileio_stream_spec::deploy_error_rollback_sweeps_stream_fds` and
  adds the nested-checkpoint parity pin
  `nested_soft_checkpoints_preserve_outer_dir_fd_snapshot`.
- `7b6e33911` Step 5 — `Dir.rho::entries()` swapped to
  `entriesStreamOpen/Next/Close`.  Genesis anchor rolled
  `434a828b` → `60035818`.  Producer wrapper adapts the 2-element
  `[false, "EOS"]` native terminator to the 3-element
  `[false, "EOS", msg]` shape Stream.rho expects and closes the fd
  on EOS + error branches.
- `a3f5406f5` Step 7 — runtime pin
  `fs_entries_stream_streams_five_children_charges_supplement_at_runtime`
  drives 8 native calls end-to-end and asserts the per-call charges;
  ceiling widened to `+30_000` (measured ~21_000 harness overhead
  vs. bulk's ~500).
- `da9bdc9f5` Step 8 — narrowed the source-scan pin to `fs_remove_dir`
  only; renamed to `remove_dir_charges_setup_only_pending_reply_shape_change`.
- `b7f04dd74` Review-fixup A — Dir.rho malformed-close +
  docstring correction.  The producer wrapper's defensive
  malformed-reply arm now closes the stream fd before responding
  FSERR_IO.  Docstring corrected: Step 5's original claim that
  `WalDeployScope::Drop` sweeps via
  `DirHandleTable::close_all_for_deploy` was verified false and
  removed — the sweep API exists but is unwired; see the
  "Dir-stream fd deploy-end sweep" deferred item.  EOS-shape
  brittleness pinned via comment on the match arm.  Genesis
  anchor rolled `60035818` → `5efce8f422d240b2e271fd7407d0a80e6c2a62302195fb8cce42c13dabf00c5e`.
- `5c9b18dbd` Review-fixup B — coverage additions across
  five test files: `reset_clears_dir_fs_snapshot_stack` +
  `unbalanced_dir_revert_without_matching_create_is_no_op`
  (Step 4); `dir_entries_mid_stream_error_closes_stream_fd` +
  `dir_entries_eos_closes_stream_fd` +
  `open_without_close_leaves_fd_in_table` (Step 5);
  `fs_entries_stream_empty_dir_charges_setup_only_at_runtime`
  (Step 7); `arity3_entries_stream_stub_still_returns_fserr_unsupported`
  (Step 8).  Mock preamble in `file_dir_check.rs` gains a
  `streamCloseLog` counter and mid-stream error injection via
  `("__err", code, msg)` sentinel.

**Final test posture at head `5c9b18dbd`:** `io::` lib 270/270,
`fs_wal_spec` 33/33, `fs_next_fd_seed_spec` 6/6, `fileio_stream_spec`
10/10 (was 9/9 → +1 leak-visibility pin), `fileio_lifecycle_spec` 4/4
(was 2/2 → +reset-clear + unbalanced-revert),
`fileio_cost_spec` 73/73 (was 72/72 → +arity-3 stub pin),
`fileio_cost_runtime_spec` 4/4 (was 3/3 → +empty-dir streaming),
`fs_genesis` 38/38 (golden hex rolled twice through the slice),
casper genesis-contracts fileio E2E 53/53 (2 ignored PB-B-5),
rholang `file_dir_check` 497/497 (was 495/495 → +2 close-branch pins).

**Remaining deferred (updated during review pass):**
* bulk `fs_entries` `reserve_primitive(0)` bug on empty dirs — cost-
  helper audit territory; see Deferred items catalog.
* `fs_remove_dir` per-entry supplement pending reply-shape change.
* Dir-stream fd deploy-end sweep NOT wired — new deferred item
  surfaced during Steps 4-8 review; see catalog entry.  Mitigated by
  MAX_OPEN_FDS cap + per-block runtime respawn until wired.
* Consensus-mode replay pin via `Dir.entries()` (leader/follower
  byte-identity through Dir.rho → producer wrapper → streaming
  natives → WAL) — blocked on the already-tracked Layer 2 two-runtime
  harness (see Phase 10 open items).
* E2E `Dir.entries()` against the real streaming handler (not just
  mocks) — blocked on the same harness as consensus replay above.

The pickup notes below are preserved as-is for historical reference
during any post-mortem or review of the slice's design choices.

---

### Streaming-backing slice — Steps 1-3 landed; Steps 4/5/7/8 pickup (fresh-session, 2026-08-25)

**Current state (branch `fileio-phase-1-2`, head `5c2419169`):** Steps 1-3 shipped and pushed.  Six commits comprise the slice so far:
- `d7b69bb40` Step 1 DirHandleTable + 18 unit tests
- `299707d62` Step 1 fixup — swap `tokio::fs::ReadDir` → `libc::DIR*` for TOCTOU-immunity parity with bulk `fs_entries`
- `d70ca8235` Step 2 three natives + wiring (oracular happy path)
- `4089127c1` Step 2 fixup — `Box<Par>` in `Result::Err` for clippy `result_large_err`
- `ac7bb9b6a` Step 3 D3 WAL wiring for `entriesStreamNext`
- `5c2419169` Review fixups — seed `dir_handles.next_fd` from state hash + 8 additional test pins

**Test posture at head:** `io::` lib 270/270, `fs_wal_spec` 33/33, `fs_next_fd_seed_spec` 6/6, `fileio_stream_spec` 7/7 + 1 ignored (Step-4 placeholder), `fileio_cost_spec` 72/72.  Clippy clean.

**Deferred latent bug** (documented in Step 3 commit body, out of scope for streaming slice): bulk `fs_entries` also has the `reserve_primitive(0)` → `BugFoundError` bug on empty dirs.  Streaming's Step 3 uses `reserve_incremental_primitive` (which early-returns on zero) — bulk uses the wrong helper.  No existing test catches it because the empty-dir cost test only observes setup cost, not the supplement error path.  Broader cost-helper audit; fold into a fs_entries fixup slice.

**Step 4 — snapshot/rollback integration.** Wire `DirHandleTable::snapshot_next_fd` + `truncate_to` into the same fs snapshot stack that already handles file fds.  Two touchpoints in `rholang/src/rust/interpreter/rho_runtime.rs`:
1. `RhoRuntime::create_soft_checkpoint` (currently line ~526) pushes `self.fs_handles.snapshot_next_fd()` onto `fs_snapshot_stack`.  Extend to also push `self.fs_handles.dir_handles.snapshot_next_fd()` — needs a companion stack, or push a tuple, or add a second `dir_fs_snapshot_stack: Arc<Mutex<Vec<u64>>>`.  The second-stack approach is a smaller diff and matches the existing pattern for WAL (`wal_snapshot_stack` is separate from `fs_snapshot_stack`).
2. `RhoRuntime::revert_to_soft_checkpoint` (~line 578) pops and calls `truncate_to`.  Add symmetric pop for the dir snapshot.
Also update `reset()` (line ~655) to clear the new stack.  The already-committed `fileio_stream_spec::deploy_error_rollback_sweeps_stream_fds` test is `#[ignore]`d — drop the ignore once wired; it becomes the regression pin.  Nested-checkpoint parity: mirror `nested_soft_checkpoints_preserve_outer_fd_snapshot` in `fileio_lifecycle_spec.rs`.

**Step 5 — `Dir.rho::entries()` swap.** Read `casper/src/rust/genesis/contracts/rho/Dir.rho:127-149` first.  Current body materializes `fs_entries` result into a `listState` and pops one-at-a-time from an `entryProducer` contract.  New body: `entriesStreamOpen!(root, rel, cmode, *fdRet) | for(@fdReply <- fdRet) { ... }` — mint a `Stream` around `entriesStreamNext(streamFd)`; on `Stream.EOS` (or consumer drop) call `entriesStreamClose(streamFd)`.  Bindings for `fsEntriesStreamOpen`/`Next`/`Close` are already in the composed FsGenesis outer `new` clause (Step 2 landed).  Genesis anchor roll — fs_genesis.rs golden hex will trip; update `EXPECTED` in `compose_fs_genesis_source_golden_hex` (currently `434a828b`).  Hard-fork surface: yes — changes composed source deploy-content hash.  Log the roll.

**Step 7 — cost runtime pin.** Add `fs_entries_stream_streams_five_children_charges_supplement_at_runtime` to `rholang/tests/fileio_cost_runtime_spec.rs`.  Fixture: 4 files + 1 subdir (5 children).  Term: open stream, drive 6 Next calls (5 yields + 1 EOS), close.  Assert: `consumed >= fs_entries_stream_open_cost() + 5 * fs_entries_stream_next_cost() + 5 * fs_entries_stream_per_entry_supplement_cost(1) + 1 * fs_entries_stream_next_cost() + fs_entries_stream_close_cost()`.  Upper bound: `lower_bound + 5000` (same ceiling as bulk `fs_entries` pin).  Companion to `fs_entries_five_children_charges_supplement_at_runtime`.

**Step 8 — source-scan pin cleanup.** `rholang/tests/fileio_cost_spec.rs::entries_stream_and_remove_dir_charge_setup_only_pending_blocker_resolution` currently documents "no per-entry supplement wired, and that's OK because handler is a stub."  Once Step 3 landed, the streaming supplement wires up.  Either delete that pin (subsumed by Step 7 runtime pin) or narrow it to `fs_remove_dir` only (still blocked on the `[true, n_deleted]` reply-shape change).  Recommendation: narrow — the fs_remove_dir gap is a separate deferred item.

**Toolchain gotcha** (still applies): every `cargo` command needs `PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09`; every `git commit` needs those PLUS `SKIP_DENY=1 SKIP_CLIPPY=1 SKIP_TESTS=1`; `git push` needs `SKIP_TESTS=1` but MUST keep clippy on (the pre-push clippy caught the `result_large_err` on Step 2).  Never amend commits — root-cause hook failures with fixup commits instead.

## Cost-accounted-rho merge — landed (2026-08-21)

`origin/feature/cost-accounted-rho` — the D3 migration (internalized cost accounting via `RuntimeBudget` + `BillableTokenEvent` + `MeteredMachine`, replacing `CostManager` + `ChargingRSpace`) — merged into `fileio-phase-1-2` on 2026-08-21.  Merge commits `018549c12` / `f2e9e109b` / `37422f95e` / `a2cd425f9` / `2dc106efe`.  Post-merge test posture: fs_wal_spec 29/29, casper fileio+fs_generator 39/2, file_dir_check 491/3.  See `merge-cost-accounting-plan.md` in this directory for the actual integration narrative and conflict resolutions.

**Post-merge consequences that shape ongoing work:**

- Phase 9 uses Path B (`BillableTokenEvent::Primitive` from day one; no port work needed).
- WAL boundary lives inside `process_deploy_cosigned_with_budget_and_authority_mode`; return chain uses `Vec<WalEntry>` 4-tuples; every handler charge feeds the D3-canonical `authority_cost_witness.realized`.
- Every fs native charges via `metering.reserve_primitive(...)` at handler entry (or post-reply for two-branch charges — see §Phase 9).

## Development conventions

**Commits on `fileio-phase-1-2`**:

- Subject: `<type>(fileio): <slice-tag> <summary>`.  Match style of `git log --oneline -20`.
- Body: prose paragraphs.  Reference slice tags / finding IDs (M-x, H-x, F-x) in-body where relevant.
- Trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

**Pre-commit hooks**:

- `[fmt]` `[clippy]` `[deny]` run automatically.
- `[deny]` fails on pre-existing `bitmaps` / `h2 RUSTSEC-2026-0258` warnings unrelated to fileio work.  Use `SKIP_DENY=1 git commit -F <msgfile>` to bypass just that check.  Do NOT use `--no-verify`.
- `[fmt]` failures: `cargo fmt --all`, then re-add + re-commit.  Workspace `rustfmt.toml` prints cosmetic `.expect too high` warnings on `fn_call_width` / `attr_fn_like_width` / `array_width` — ignore.

**Toolchain gotcha** — workspace pins nightly-2026-02-09 via `rust-toolchain.toml`; MacPorts stable cargo ignores that file.  **Prefix EVERY cargo command and every `git commit`**:

```
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 cargo <cmd>
PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 SKIP_DENY=1 git commit -F /tmp/<msg>.txt
```

See `.claude/memory/f1r3node_toolchain.md`.

**Push convention**: `PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=nightly-2026-02-09 SKIP_TESTS=1 git push origin fileio-phase-1-2`.  `SKIP_TESTS=1` because the workspace pre-push hook enforces a 600s per-crate timeout that's unrealistic for this workspace; local test-suite verification is sufficient.

**Commit-message file workflow** — avoids bash heredoc quoting issues with em-dashes, apostrophes, backticks:

```
# Write msg to /tmp/<name>.txt via Write tool, then:
SKIP_DENY=1 git commit -F /tmp/<name>.txt
```

**Two-commit pattern for slices adding new files**: `git commit -a` does NOT stage untracked files.  Either explicitly `git add` new files before commit, or expect a follow-up commit picking them up.

**Testing during slice work**:

- `cargo check -p rholang` — fast compile check.
- `cargo test -p rholang --lib io::` — all File I/O unit tests.
- `cargo test -p rholang --lib io::lock` — LockRegistry.
- `cargo test -p casper --lib fs_genesis` — golden hex + drift checks.
- `cargo test -p rholang --test file_dir_check with_libs_composes` — quick compile check that composed source parses.
- Full `cargo test -p rholang --lib` takes ~2.5 min; use for pre-commit sanity.

**Two-repo state**: code lives in `f1r3node-rust` at `/Users/stay/greg/f1r3fly/f1r3node-rust` (git repo); FIP spec + implementation plan live in FIPS at `/Users/stay/greg/f1r3fly/FIPS/fileio/` (NOT a git repo — local edits only, no push).  Synchronize manually: design memos land in FIPS, code lands in f1r3node-rust.

**Untracked local scripts**: `startnode`, `startrepl` appear in `git status` — user's local test helpers, don't touch.

## Fresh-session pickup — post-2026-08-26 head (`7323f391f`)

**Current state (branch `fileio-phase-1-2`, head `7323f391f`):** streaming-backing slice complete (Steps 1-8 + fixups A/B); cost-helper audit landed (`d0df35476`); Phase 8 review follow-ups closed (`e578ae9dd`); cost-accounted-rho merge landed (`1c28f53a2`); post-merge polish landed (WalSnapshotWrite effect kind `9b87565b7`, Phase 8 arity tightening `5e8f3e2a0`, randomized tokio stress `f7c0736b0`, PB-M-14 scaffold + multi-deploy WAL `7630b00de`); review-fixup test coverage + lock-ordering audit landed (`f15be8302` + `7323f391f`).

**Test posture at head:** io lib 270/270, rholang integration 645/645 + 1 ignored (PB-M-14 scaffold), casper fs_genesis 39/39, casper fileio E2E 53/53, casper lib 594/594.  Full sweep command in the Development conventions section.

### Unblocked next-session items

Three items are unblocked and can be picked up without design decisions.  Listed in priority order (highest downstream unlock first):

1. **Layer 2 two-runtime harness** — highest-leverage unblock (four downstream items: Phase 10d oracular replay E2E, `fileio_replay_spec.rs`, consensus-mode replay pin via `Dir.entries()`, E2E `Dir.entries()` through the real streaming handler).  Two paths:
   - **Path A (extend `create_leader_and_follower`):** smaller scope.  The existing helper in `rholang/tests/fs_wal_spec.rs:820` runs leader + follower in the same process against a shared store via `RSpace::create_with_replay`.  Extend to: (i) a "fresh follower" variant that starts from an empty store and applies the leader's checkpoint hash without rig (so replay must reconstruct state from WAL only); (ii) **a helper that runs N leader deploys, drains the WAL, and re-executes them on a fresh follower via WAL replay (not tuplespace rig).  LANDED 2026-08-26** as `apply_wal_to_fresh_tree` in `rholang/tests/fs_wal_spec.rs` — a fresh-tree WAL applier that reconstructs on-disk file state from a captured WAL + payload-bytes sidecar (Phase-7b-style hash→bytes lookup).  Test `pb_m_14_file_state_identity_via_wal_replay` closes the FILE-STATE-IDENTITY half of PB-M-14; test `wal_applier_skips_failure_outcome_entries` pins the H-6 Failure-outcome skip.  Applier is restricted to `WriteAt`/`Truncate` — sequential `Write` reconstruction surfaces a WAL-shape gap tracked in the Deferred items catalog ("WAL fresh-tree applier: sequential-Write reconstruction").  Path A(i) — "fresh follower via checkpoint hash without rig" — is NOT landed; unclear it's actually needed after the applier route validates the byte-identity story more directly.
   - **Path B (`TestNode` retrofit):** larger scope.  Add per-node fs provisioning + observation hooks to `casper/tests/helper/test_node.rs::create_node` — see the docstring on `fs_wal_spec::pb_m_14_two_validator_scaffold` for the concrete gap list.  Produces full E2E test with network-layer block propagation.
   - **Recommendation (updated 2026-08-26):** with Path A(ii) landed, the four downstream items previously blocked on "the harness" split cleanly.  Phase 10d oracular replay E2E and `fileio_replay_spec.rs` don't require fresh-tree file reconstruction — they need leader/follower runtime symmetry, which the shared-store `create_leader_and_follower` already provides.  Those two items are unblocked NOW; the missing piece is test-authoring, not infrastructure.  The full two-validator PB-M-14 network E2E (`pb_m_14_two_validator_scaffold` docstring) still needs Path B.

2. **Phase 7b protocol implementation** — byte-payload distribution.  Design memo at implementation-plan.md:374-377 (Option C).  Infrastructure survey in Deferred items catalog `Phase 7b` entry: no existing scaffolding, `BlockRetriever` at `casper/src/rust/engine/block_retriever.rs:79` is the extension template.  Concrete scope:
   - **Phase 7b-1 (snapshot chunk-fetch):** `SnapshotChunkRetriever` mirroring `BlockRetriever`'s `RequestState`/timeout/retry/peer-set shape; new wire opcodes `get_snapshot_chunk` request/response + broadcast variants; Merkle chunker over 4 MiB pieces with per-chunk Blake2b256 hashes, root = Merkle root.  PB-M-15's `WalSnapshotWrite` effect kind (landed `9b87565b7`) already commits the snapshot root on-chain, so the Merkle-root commitment side is done.
   - **Phase 7b-2 (between-snapshot payload fetch):** `WalPayloadRetriever` — same shape as Phase 7b-1 but keyed on payload hashes referenced by the WAL slice between the joiner's latest snapshot and the head block.  Also covers the "write-payload determinism" reducer: bytes traceable to on-chain sources (deploy data + deterministic Rholang) don't need `get_wal_payload` requests — the joiner replays deploys and produces the bytes locally.  Only writes whose bytes originate outside the reproducibility chain fall back to fetch.
   - **Estimate:** multi-session, 3-5 files across `casper::engine`, `models`, `comm`.
   - **Recommendation:** land Phase 7b-1 first (snapshot fetch); it exercises the Retriever/opcode pattern with a bounded byte-count per fetch (4 MiB chunks).  Phase 7b-2 reuses everything and adds the on-demand + reducer logic.

3. **`fileio_native_spec.rs`** — direct-URN dispatch coverage for each native.  Low priority per prior classification (natives are unit-tested and reached transitively through Dir.rho / File.rho / Fs.rho).  Needs a genesis-scope URN-filter toggle in test source so the natives are dispatchable from a user-scope deploy.  ~50-100 LOC test + a small helper.  Good for a "warmup" bite that doesn't require touching production code.

### Deferred design decisions (still gating other work)

Not to be confused with the unblocked items above.  These need a human call before implementation can start:

1. **Dir-fd deploy-end sweep coupling** — dir alone or file+dir together?  async-in-sync-Drop strategy (block_on / block_in_place / explicit commit call)?  Security-review finding from the streaming-slice review pass; DoS mitigation gap for adversarial Rholang.  See Deferred items catalog entry `Dir-stream fd deploy-end sweep`.
2. **`fs_remove_dir` reply-shape change** — `[true, n_deleted]` (ripples through Dir.rho + file_dir_check + fs_generator callers; hard-fork surface) OR flat subtree-entry budget cap (caller UX degrades).
3. **Powerbox stub scope** — per-`deployerId` cap issuance with revocation, or lighter?  Blocks Phase 10e (`fileio_cross_fs_isolation.rho`) + `fileio_membrane.rho` example.
4. **`MAX_WAITERS_PER_FILE` cap** (Phase 8 NB-3) — threshold value + hard-fork surface acknowledgement.
5. **readLineInto arity-N+1 wait-variants** (Phase 8) — spec ambiguity; needs semantics decision.

## Definition of done

- All 10 phases complete; `cargo test` and the casper integration suite pass.
- `Fs` published at `rho:io:fs:1.0.0`; allocator published at `rho:lang:buffer:1.0.0`; both resolvable via the versioned registry.
- Each of the 10 example `.rho` scripts listed in Phase 10 (`fileio_static`, `fileio_buffer_loop`, `fileio_stdio`, `fileio_membrane`, `fileio_readonly_forwarder`, `fileio_parallel`, `fileio_chown_consensus`, `fileio_rows`, `fileio_cross_fs_isolation`, `fileio_lockrange`) runs on a fresh node with static config and produces the documented behavior.
- Replay: each example's lead-node run replays byte-identically on a follower.
- Consensus-mode oracular replay CI slice runs green.
- Boot-time validation rejects a tree containing symlinks / hard-links with a clean fail-to-launch error.
- Legacy `rho:io:stdout` / `rho:io:stderr` still work (deprecated but not removed).
- Deferred items (§Deferred in the spec) explicitly not attempted.
