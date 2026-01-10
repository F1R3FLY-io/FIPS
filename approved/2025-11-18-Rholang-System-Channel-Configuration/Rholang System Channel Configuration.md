# Rholang System Channel Configuration

Michael Stay ([director.research@f1r3fly.io](mailto:director.research@f1r3fly.io))  
2025-11-18

# Introduction

At the moment, system channels have to be added to the source code of the node itself (e.g. [openai\_service.rs](https://github.com/F1R3FLY-io/f1r3node/blob/rust/dev/rholang/src/rust/interpreter/openai_service.rs)). This clearly does not scale. We need a way to expose system resources as [agents](https://docs.google.com/document/d/13VvNssV67MslHvxycAgywbODodj1ZIBxbxc-TE3oOBo/edit?tab=t.0#heading=h.5g7i17e5p09f) to Rholang code.

The goal of this document is to specify how the node maps Rholang “system-channel” URIs to operating-system resources (files, pipes, sockets, etc.), and what API those resources expose as agents.

## Business Opportunity

Modern LLMs are extremely vulnerable to *prompt injection*: any untrusted text the model reads (web pages, emails, logs, user content, etc.) can contain hidden instructions that override system prompts, leak secrets, or steer tool calls in unexpected ways. Once an LLM has access to powerful tools—files, network sockets, payment APIs, administrative control surfaces—an injection bug is no longer just a bad answer; it can become a remote code-execution primitive against the surrounding system.

The only sane response is to apply the *principle of least authority* (POLA) to tool-using LLMs. A given LLM instance (or “agent”) should see only the minimal set of capabilities required for its task: a narrow log file, not the whole filesystem; an HTTP client scoped to a particular domain, not arbitrary sockets; a single database table, not the entire cluster. In particular, we want to avoid any form of ambient authority (implicit globals, “root” handles, or ad hoc escape hatches) that an injected prompt could discover and exploit.

Rholang is already built around an object-capability model. An *agent instance* in Rholang is an object capability: holding a reference to an agent is exactly the authority to invoke its methods, and there is no way to forge additional authority without someone explicitly passing you more capabilities. System channels, when mapped into Rholang as agents, therefore become first-class, composable object capabilities for OS-level resources.

This makes Rholang an ideal platform for hosting tool-using LLMs. We can represent each OS resource as a narrowly-scoped agent, wire those agents into LLM-facing code via explicit channel passing, and rely on the object-capability discipline to ensure that:

* An LLM instance can only invoke the tools (agents) it has been explicitly given.  
* Different LLM instances can be sandboxed by giving them disjoint sets of agents.  
* Security policies can be enforced at configuration time, by controlling which system-channel URIs are available and how they are mapped to concrete OS resources.

The system-channel configuration described in this document is thus not just a convenience for wiring up I/O; it is part of the security boundary for LLM-based systems. By treating OS resources as object capabilities and exposing them through Rholang agents, we obtain a clean, auditable surface for managing and constraining tool-using LLMs.

# File agents

Unix and its derivatives use files as the unit of communication. We can back an agent with a file, named pipe, or other OS-level file descriptor.

A **file agent** is an agent whose methods provide read/write-style access to an underlying file descriptor. In Rholang user code, the agent is called via the `agent` sugar and method-call sugar described in the “Agents” document, e.g.

```
new f(`rho:io:system-channels:foo:bar`) in {
  for(@data <- f!read(1024)) {
    // ...
  }
}
```

where `f` is a `File` agent instance.

## File Agent API

The methods on a file agent are essentially the `FILE*` functions provided by `stdio.h`. We do not, however, support the full `printf` / `scanf` spec, as it has security issues; the subset we do support is described below.

Each method is exposed as a Rholang agent method and is normally called using method-call sugar:

```
for(result <- file!methodName(args...)) { ... }
```

On success, methods return either the requested value or an appropriate status (e.g. number of bytes written). On error, methods should return a `(false, error)` tuple, where `error` is a machine-readable error code or string, and on success `(true, value)`. The exact error-code set is implementation-defined, but should at least distinguish common POSIX errors (ENOENT, EACCES, EIO, etc.).

Below, `file` denotes a file agent instance.

---

### `read`

**Signature (conceptual)** `file!read(maxBytes: Int) : (Bool, Bytes)`

**Description** Reads up to `maxBytes` bytes from the current file position. On success, returns `(true, data)` where `data` is a `ByteArray` value (or possibly a UTF-8 `String` for text-mode files, depending on how the runtime distinguishes binary vs text). On EOF, returns `(true, empty)` (or an empty string). On error, returns `(false, error)`.

**Notes**

* A `maxBytes` value of `0` is allowed and must return immediately with an empty buffer.  
* The method advances the internal file position by the number of bytes actually read.  
* Implementations SHOULD be non-blocking at the interpreter level if the underlying descriptor is non-blocking; otherwise they block the OS thread but not the Rholang scheduler.

Example:

```
for(@(true, data) <- file!read(4096)) {
  // consume data
}
```

---

### `write`

**Signature** `file!write(data: Bytes | String) : (Bool, Int)`

**Description** Writes the contents of `data` starting at the current file position. Returns `(true, nBytesWritten)` on success, `(false, error)` on error.

**Notes**

* For text-mode files, `String` arguments are encoded as UTF-8.  
* The method MAY perform partial writes; the caller must check `nBytesWritten` and potentially retry.  
* Advances the file position by `nBytesWritten`.

Example:

```
for(@(ok, n) <- file!write("hello\n")) {
  if (ok) {
    // ...
  } else {
    // handle error
  }
}
```

---

### `seek`

**Signature** `file!seek(offset: Int, whence: String) : (Bool, Int)`

**Description** Changes the current file position. `whence` is one of `"set"`, `"cur"`, `"end"`, corresponding to `SEEK_SET`, `SEEK_CUR`, `SEEK_END`. Returns `(true, newPos)` on success, `(false, error)` on error.

**Notes**

* `offset` is a signed integer; negative values are allowed when `whence` is `"cur"` or `"end"` when supported by the OS.  
* On success, `newPos` is the absolute byte offset from the beginning of the file.

Example:

```
for(@(true, pos) <- file!seek(0, "end")) {
  // pos is file length
}
```

---

### `close`

**Signature** `file!close() : (Bool, Nil)`

**Description** Closes the underlying file descriptor. After `close` succeeds, all further method calls on the agent MUST fail with an appropriate error (e.g. `"EBADF"`). Returns `(true, Nil)` on success, `(false, error)` on error.

**Notes**

* Implementations SHOULD be idempotent: multiple `close` calls either all succeed or all return a consistent “already closed” error.

---

### `flush`

**Signature** `file!flush() : (Bool, Nil)`

**Description** Flushes any buffered output for the file agent to the underlying OS file descriptor, analogous to `fflush`.

**Notes**

* For read-only descriptors, `flush` is a no-op that returns success.

---

### `getc`

**Signature** `file!getc() : (Bool, Int)`

**Description** Reads a single byte (or Unicode scalar in text mode) from the file. On success, returns `(true, code)`, where `code` is the integer codepoint (0–255 for byte mode). On EOF, returns `(true, -1)` (or another distinguished sentinel). On error, returns `(false, error)`.

**Notes**

* `getc` is essentially `read(1)` with a more convenient scalar result.

---

### `putc`

**Signature** `file!putc(code: Int | String) : (Bool, Int)`

**Description** Writes a single byte or character to the file. Returns `(true, 1)` on success, `(false, error)` on error.

**Notes**

* If a `String` is provided, it MUST be either length 1 in characters or the implementation must treat only the first character as significant.  
* In text mode, the character is encoded as UTF-8.

---

### `gets`

**Signature** `file!gets(maxBytes: Int) : (Bool, String)`

**Description** Reads a line of text from the file, up to and including the terminating newline or until `maxBytes` bytes have been read, whichever comes first. Returns `(true, line)` on success, where `line` is a UTF-8 `String` that may or may not include the trailing newline, depending on configuration. On EOF before any bytes are read, returns `(true, "")`. On error, returns `(false, error)`.

**Notes**

* Implementations SHOULD guarantee that the returned string is valid UTF-8.  
* `maxBytes` is a safety cap to avoid unbounded memory usage on untrusted input; the implementation MAY clamp or reject excessively large values.

---

### `puts`

**Signature** `file!puts(line: String) : (Bool, Int)`

**Description** Writes a line of text to the file. Implementations MAY append a trailing newline if one is not present, matching traditional `puts` semantics, or they may require the caller to include the newline. Returns `(true, nBytesWritten)` on success, `(false, error)` on error.

**Notes**

* The exact newline convention (auto-append vs literal) MUST be documented by the implementation; for portability we recommend **not** auto-appending and instead treating `puts` as a thin wrapper over `write`.  
* The `puts` method plays the role of `printf` since rholang already has string interpolation.

---

### `scanf`

**Signature** `file!scanf(fmt: String) : (Bool, List[Any])`

**Description** Parses formatted input from the file according to a restricted `scanf`\-style format string `fmt`. Returns `(true, values)` where `values` is a list of parsed values (ints, floats, strings, etc.), or `(false, error)` if parsing fails or input is exhausted.

**Security and limitations**

To avoid the complexity and security pitfalls of full `scanf`, we support only a small, well-defined subset of format specifiers, for example:

* `%d` – decimal integer  
* `%u` – unsigned integer  
* `%f` – floating-point number  
* `%s` – whitespace-delimited UTF-8 string

No width modifiers, no `%n`, no dynamic-width specifiers, and no direct memory-address semantics are supported.

Implementations MAY choose to omit `scanf` entirely; in that case, the method should consistently return `(false, "ENOTIMPL")`.

---

### Wide-character functions

The C stdio API also exposes wide-character functions (`fgetwc`, `fputwc`, etc.). Rholang strings are UTF-8 by construction, so we do **not** expose a separate “wide” API initially.

Instead:

* Text-mode operations (`gets`, `puts`, `scanf`) operate on UTF-8 strings.  
* Binary-mode operations (`read`, `write`, `getc`, `putc`) operate on raw bytes.

If a future need arises for explicit UTF-16 or UTF-32 file operations, we can introduce separate agents or additional methods, but the base file agent API is UTF-8–centric.

## TOML configuration

The Rholang interpreter should take a TOML configuration file. The super table `system-channels` maps Rholang colon-paths to files or named pipes. The colon-paths all get prefixed by `rho:io:system-channel:` at the URI level, so

```
[system-channels.foo.bar]
name = "bar.txt"
mode = "r"
type = "file"        # "file" | "pipe" | "socket" (future)
encoding = "utf-8"   # or "binary"
create = false       # if true, create if missing
truncate = false     # if true, truncate on open
append = false       # if true, open in append mode
buffered = true      # if false, use unbuffered I/O
```

allows `bar.txt` to be imported as an agent via

```
new bar(`rho:io:system-channels:foo:bar`) in { ... }
```

### Table layout

* The table name after `system-channels.` determines the colon-path segment(s). For example:  
    
  * `[system-channels.stdout]` → `rho:io:system-channels:stdout`  
  * `[system-channels.kernel.logs.http]` → `rho:io:system-channels:kernel:logs:http`


* All tables under `system-channels` MUST have at least:  
    
  * `name` – the OS-level path or special name (e.g. `"stdout"`, `"stdin"`, `"stderr"`, `"fifo:/var/run/foo"`).  
  * `mode` – `"r"`, `"w"`, `"rw"`, `"a"`, possibly with `+` modifiers.


* Optional fields:  
    
  * `type` – `"file"` (default) or `"pipe"` or `"socket"` (reserved for future).  
  * `encoding` – `"utf-8"` (default) or `"binary"`.  
  * `create` – boolean; if true, create missing files with default permissions.  
  * `truncate` – boolean; if true and opening for write, truncate existing file.  
  * `append` – boolean; if true, open in append mode.  
  * `buffered` – boolean; if false, disable user-space buffering.  
  * `permissions` – optional string like `"0644"` to control file creation mode.

### Resolution rules

* The TOML file is loaded at node startup.  
    
* For a URI `rho:io:system-channels:x:y:z`, the interpreter:  
    
  1. Strips the prefix `rho:io:system-channels:` and splits `x:y:z` into segments.  
  2. Looks for the TOML table `[system-channels.x.y.z]`.  
  3. If not found, it panics with a runtime error.

## Command-line flags

The node needs a way to select which TOML configuration file to use and to override specific mappings without editing the file. This is especially important for testing, local development, and containerized deployments.

### Change the config file

The node SHOULD accept a command-line flag to specify the system-channel configuration TOML file, e.g.

* `--system-channels-config /path/to/system-channels.toml`

Behavior:

* If the flag is provided, the node loads the given file instead of the default.  
    
* If the file cannot be read or parsed, the node SHOULD fail fast with a clear error message.  
    
* The default search order (if the flag is **not** provided) might be:  
    
  1. `${RHO_SYSTEM_CHANNELS_CONFIG}` environment variable, if set.  
  2. `./system-channels.toml` (relative to the working directory).  
  3. `/etc/f1r3node/system-channels.toml` or another build-time default.

Implementations SHOULD document the actual default path(s) and environment variable name, but the pattern above provides a predictable override hierarchy:

1. CLI flag  
2. Environment variable  
3. Built-in default

### Override mapping

Sometimes it is useful to override just one or two channels without touching the TOML file (e.g. redirecting `stdout` to a test log, or pointing a particular channel to a local FIFO).

To support this, the node SHOULD accept one or more flags of the form:

* `--system-channel OVERRIDE`  
* or a short form like `-S OVERRIDE`

where `OVERRIDE` has the syntax:

```
path=name,mode[,encoding=...,type=...,create=...,truncate=...,append=...,buffered=...]
```

Examples:

```shell
# Redirect system stdout to /tmp/stdout.log in append mode:
f1r3node \
  --system-channel stdout=/tmp/stdout.log,mode=a,encoding=utf-8,append=true

# Override a nested channel:
f1r3node \
  --system-channel kernel.logs.http=/var/log/http.log,mode=rw,encoding=binary
```

Semantics:

* `path` is the TOML table suffix, e.g. `stdout` or `kernel.logs.http`.  
* `name` is the OS-level resource path.  
* `mode` is required.  
* Additional key–value pairs override corresponding TOML keys for that channel only.

Resolution order for a given channel:

1. Command-line overrides (highest precedence).  
2. Values from the TOML configuration file.  
3. Built-in defaults (e.g. mapping `stdout` to the process stdout).

This means you can:

* Use TOML for the canonical description of all system-channels in production.  
* Use command-line flags to tweak mappings in tests or local runs without editing the TOML or rebuilding the node.

Implementations MAY also support a special path `*` to mean “apply this override to all channels matching a pattern”, but that is optional and not part of the minimal spec here.

---

## Future work / open questions

* **Error model**: this document recommends returning `(Bool, valueOrError)`, but the node’s Rholang runtime may eventually standardize a richer error handling mechanism (exceptions, structured error types).  
* **Non-file resources**: sockets, HTTP endpoints, and other capabilities can reuse the same configuration machinery, but will need their own agent APIs.  
* **Security & sandboxing**: the TOML and CLI override mechanisms should respect node-level security policies (e.g. disallow mapping system-channels to arbitrary paths when running in a restricted environment).  
* **Hot reload**: support for reloading system-channel mappings at runtime is out of scope here, but could be considered later.
