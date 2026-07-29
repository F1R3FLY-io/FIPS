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
- URN filter in `rho_runtime::is_internal_urn` (`starts_with("rho:io:fs:native:")`).
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
  - Cached agent instances per `(canonicalPath, resolvedMode)` on the *same* `Fs` instance.  Cache scoped by `Fs`-instance (per-principal).
- `Stdin.rho`: `chars`, `bytes`, `lines`, `readLine`, `close`; positional methods `"FSERR_UNSUPPORTED"`.
- `Stdout.rho`: `writeChars`, `writeBytes`, `writeLine`, `writeLines`, `writeString`, `writeByteArray`, `flush`, `close`; read methods `"FSERR_UNSUPPORTED"`.
- Genesis deploy source (`FsGenesis.rho` or similar) that composes all library classes in a single `new` scope binding the native URNs via `NormalizerEnv` injections, then publishes `Fs` at `rho:io:fs:1.0.0`.
- `StandardDeploys` entry for the genesis deploy.
- ~~`Registry.rho` signed shorthand entry for `rho:io:fs:1.0.0`.~~ **Deferred to the Powerbox slice** (see `powerbox-requirements.md` PB-B-3): the FsGenesis deploy publishes at `rho:id:<hash>` derived from `FS_GENERATOR_PK`; the canonical `rho:io:fs:1.0.0` shorthand will be wired when per-principal Fs delegation lands and the powerbox becomes the URN resolver.
- Legacy `rho:io:stdout` / `rho:io:stderr` shim contracts marked deprecated (removal target `rho:io:fs:2.*`).  Slice 20 delivered this via code-comment + spec docstring only — no runtime signal, per Phase 6 whole-phase review (spec's "deprecation-notify channel" language applies only to Versioned Registry URNs, which legacy flat URNs are not).

**Design constraints**:

- The `Fs` agent's `openFile`/`openDir` fail with `"FSERR_UNSUPPORTED"` if the logical name isn't in the static bundle.
- Cache **does not cross `Fs` boundaries** — each principal gets a fresh `Fs` from the powerbox.
- Stdio replay: lead-node stdin reads captured; followers replay from the log.  **Deferred to Phase 10** — the capture/replay path around `Stdin`'s `fsRead` handler wasn't wired in Phase 6.  Belongs with the E2E replay harness (`fileio_replay_spec.rs`) once the ocap examples are landing.
- Stdio in cases 4-6: default `/dev/null`-equivalent; powerbox overrides.  **Deferred to the Powerbox slice** (see PB-M-2) — Phase 6 hardwires (0, 1, 2) at `Fs!?(0, 1, 2, ...)` mint time.

**Tests**:

- Full-stack: static-config → `Fs` genesis → user deploy calls `fs!openFile("config/theme.json", {"mode": "r"})` → `file!chars()` → `chars!toString(64000)`.  **Delivered** (partial) via `casper/tests/genesis/contracts/fs_generator_spec.rs`: runs `fs_generator("root")` through the RhoSpec harness, verifies URI resolution + `openFile` empty-bundle FSERR_UNSUPPORTED + `stdout()` return shape.  Full `file!chars() → chars!toString(64000)` round-trip is deferred until Phase 7's static provisioning wires an actual `config/theme.json` bundle entry — then the Phase-10 examples exercise it end-to-end.
- Stdio: `fs!stdout()!writeString("hi")` prints; `fs!stdin()!lines()` echo loop.  **Delivered** via `fs_stdout_write_string_succeeds` + `fs_stdio_echo_lines_end_to_end` in `rholang/tests/file_dir_check.rs`.
- Cache: repeated `openFile(same-name, same-mode)` returns the same handle; repeated with different mode → distinct handle (or attenuated).  **Delivered** — slice 17 cache tests.
- **Default-arm matrix** on `Fs`, `Stdin`, `Stdout`: unknown method → `[false, "FSERR_UNSUPPORTED", ...]`.  **Delivered** — `stdin_positional_methods_return_fserr_unsupported`, `stdout_read_methods_return_fserr_unsupported`, `fs_unknown_method_after_slice_18_still_unsupported`.
- **Cross-`Fs` ocap-isolation test** (a first-class MVP test, not "once powerbox stub exists"): use the genesis machinery to construct two `Fs` instances directly with distinct `deployerId`s from the stub Powerbox; call `openFile("shared/logical/name")` on each; assert the returned `File` handles are structurally distinct agents backed by distinct fds, and that a membrane wrapped around Alice's `File` is invisible to Bob when Bob opens by the same logical name.  **Delivered** (essence) via `cross_fs_alice_manipulation_invisible_to_bob` — Alice's close on her cap has no effect on Bob's independently-obtained cap; the Rholang membrane forwarder itself is deferred (Rholang syntax requires more scaffolding than a regression test warrants; close-probe demonstrates the same isolation invariant).  Full membrane-wrapped ocap test lands with the Powerbox slice + Phase-10 `fileio_membrane.rho` example.
- Replay: end-to-end example runs on the leader, its non-deterministic events captured; a follower replay produces the same `ProcessedDeploy` tree.  **Deferred to Phase 10** — see above stdio-replay deferral.
- **Consensus-mode replay**: run the same `stat`-and-`entries` example on the leader under `Consensus` mode; capture the record shape (with host-transient fields omitted); replay on a follower and assert the reply is *byte-identical*.  Lives in `fileio_consensus_replay_spec.rs` (see §Test infrastructure).  **Deferred to Phase 7** — `ConsensusMode` is enum-threaded from Phase 1 but never SET to `Consensus` (Fs.rho has no mode arg; runtime hardcodes `Oracular`).  Setting it requires deploy-context plumbing driven by config-bucket routing (`oracle-static-*` vs `consensus-static-*`), which is Phase 7's territory.

**Powerbox stub deliverable** (see plan §494 / plan-tail powerbox note): the interim per-`deployerId` stub Powerbox listed as an in-Phase-6 deliverable was **not built**; Phase 6 shipped the shared-Fs MVP instead.  See `powerbox-requirements.md` PB-M-1 for the tracking entry and design questions Q-1..Q-8 for the delegation-mechanism trade-offs.  The stub is a dedicated future slice, blocking on: (a) `NormalizerEnv` plumbing decision (Option A / B / C in `powerbox-requirements.md` §5), (b) Phase 7's config → bundle handoff.

**Effort**: 4–5 days delivered as slices 14-20 (Stdin, Stdout, Fs.openFile/openDir, Fs.cache, Fs.stdio, FsGenesis, legacy-shim doc).  Powerbox stub not counted in this budget; slotted as a distinct future slice.

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
- Bundle passed to genesis: `Vec<(logicalName: String, canonPath: PathBuf, kind: File|Dir, mode: String)>`.
- **`ConsensusMode` setter plumbing** (moved from Phase 6 per whole-phase review B-P6-5): the config-bucket a principal's bundle came from (`oracle-static-*` vs `consensus-static-*`) determines their runtime `ConsensusMode`.  Phase 7 wires this from `DeployData` / deploy context through to `SystemProcess::new` so `handlers.rs::fs_chown` and `stat_record`'s field omission actually engage.  Phase 1 threaded the enum from `ProcessContext`; Phase 6 defaulted every principal to `Oracular`; Phase 7 provides the actual per-deploy setter.

**Design constraints**:

- Every validation error batches into a single `Vec<FileIoConfigError>` (or equivalent) so the operator sees all violations in one boot error.
- Consensus-static entries provisioned but only exercised under the deferred consensus-mode FIP.
- Mode routing (`oracle-static-*` vs `consensus-static-*`) determines the `ConsensusMode` value threaded into each principal's handler dispatch — see PB-M-12 in powerbox-requirements.md.

**Tests**:

- Config parse: valid, malformed, mode-string errors, non-absolute-path errors, `"wx"` in config, duplicate keys.
- Boot validation: temp trees with symlinks / hard-links / non-UTF-8 names.
- CLI-config equivalence: same content via flag vs. config produces the same bundle.

**Effort**: 3–4 days.

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

**Scope**: wire `CostManager::charge()` into every native and every library-method entry, with placeholder constants.

**Deliverables**:

- Per-native cost: `CostManager::charge()` at handler entry, proportional to work.
  - `open`/`close`/`stat`/`exists`/`chmod`/`chown`/`seek`/`tell`/`size`/`truncate`/`flush`/`quarantine`: constant ~100 (calibrated against `equality_check_cost`).
  - `read`/`readAt`: `c_open + bytes_read`.
  - `write`/`writeAt`: `c_open + 2 * bytes_written`.
  - `entries`: `50 + 32 * n_entries`.
  - `rename`/`copyFile`/`removeFile`: constant ~200.
  - `removeDir` recursive: `200 + per-entry cost across the tree`.
  - UTF-8 primitives: proportional to byte length.
  - `concatBytes`: linear in total byte length.
- Per-stream-method cost: per-element / per-chunk / per-byte transferred.
- Per-buffer-method cost: per §Cost accounting > Buffers.
- Materialization caps as stopgap: `toString(cap)`, `toByteArray(cap)`, `toList(cap)` with a `"FSERR_QUOTA_EXCEEDED"` reply above the cap.
- Reply-payload cap on `EntryStream.chunk(n)` (records) and `ByteStream.chunk(n)` (bytes) to bound reply payload size.  (`LineStream` doesn't support `chunk` at all per spec §chunk method, so no cap needed there.)
- **`readInto` vs. `read` cost differ.**  `readInto` is roughly 2× naive `read`: it charges the native `read` cost (bytes transferred from disk) *plus* the `writeBytes` substitution charge per parked chunk (spec §Cost accounting > Buffers: "every send additionally pays an unrefunded substitution charge proportional to its payload").  Document both formulas and expose the split so operators / users can predict per-fill cost.
- Constants calibrated against `equality_check_cost` and `sum_cost` in `accounting/costs.rs` — meaningfully more expensive than arithmetic but not prohibitive.

**Design constraints**:

- Additive to existing accounting; no repricing of prior operations.
- Constants land as tunable parameters; full calibration is the follow-up Cost FIP.

**Tests**:

- Cost regression: sample workloads (open + read + close) with expected phlogiston consumption within tolerance.
- **Buffer read cost — pairwise-merge growth.**  Measure read cost at `ν = 8`, `ν = 64`, `ν = 512` with the buffer library's balanced pairwise merge; assert the growth follows `Θ(ℓ log ν)`, NOT `Θ(ℓ ν)`.  A `ν = 1` test cannot catch a fold-vs-merge regression (nothing to merge at ν=1), so this is the actual regression guard: a future well-meaning refactor to `List.fold(concatBytes)` would silently quadruple cost between `ν = 64` and `ν = 512`, and this test would catch it.

**Effort**: 2–3 days.

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

## Definition of done

- All 10 phases complete; `cargo test` and the casper integration suite pass.
- `Fs` published at `rho:io:fs:1.0.0`; allocator published at `rho:lang:buffer:1.0.0`; both resolvable via the versioned registry.
- Each of the 10 example `.rho` scripts listed in Phase 10 (`fileio_static`, `fileio_buffer_loop`, `fileio_stdio`, `fileio_membrane`, `fileio_readonly_forwarder`, `fileio_parallel`, `fileio_chown_consensus`, `fileio_rows`, `fileio_cross_fs_isolation`, `fileio_lockrange`) runs on a fresh node with static config and produces the documented behavior.
- Replay: each example's lead-node run replays byte-identically on a follower.
- Consensus-mode oracular replay CI slice runs green.
- Boot-time validation rejects a tree containing symlinks / hard-links with a clean fail-to-launch error.
- Legacy `rho:io:stdout` / `rho:io:stderr` still work (deprecated but not removed).
- Deferred items (§Deferred in the spec) explicitly not attempted.
