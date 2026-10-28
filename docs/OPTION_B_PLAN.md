# FUTURE_OPTION B: implementation plan (constrained edge memory)

Status: **planned, not implemented.** This is the design agreed so far for
running the GCF decoder in ultra-constrained hosts (Cloudflare Workers, IoT
gateways). Sizes marked *estimate* must be measured during implementation.

## 1. Requirements (from the original brief, BRIEF.md) and decisions

| README requirement | Decision |
|---|---|
| Hard cap of **4 memory pages (256 KB)** | Fixed with linker flags: `--initial-memory=262144 --max-memory=262144`. `memory.grow` can't go past it. |
| Replace the `ArenaAllocator` with a **zero-alloc, zero-copy pointer window** over the incoming network buffer | Streaming decoder over a fixed input window. Strings are reported as offsets into the input and never copied inside wasm. |
| Manual, loop-bound stack array, **max depth 16** | **32 levels**, decided 2026-10-10. SPEC §12 requires *at least* 32 levels of nesting; 16 would reject valid documents. The extra 16 frames cost ~1 KB. |

A note on "zero-copy": WebAssembly cannot read JavaScript `ArrayBuffer`s
outside its own linear memory, so each network chunk is copied **once** into
the wasm input window. After that, nothing inside wasm copies or decodes
strings.

## 2. Why the current engine cannot simply be capped

Measured baseline (the Zig build, now `dist/gcf_zig.wasm`, at the time of
writing):

* **Initial memory:** 17 pages (~1.1 MB): 1 MiB shadow stack + 39 KB static
  data.
* **Model:** the decoder builds a complete value tree in a growing arena and
  serialises it to JSON in the same memory. Arena use scales with the
  document. A ~1 MB payload needs several MB, and even ~100 KB inputs exceed
  256 KB once the tree and the JSON output are counted.

The edge build therefore needs a different *output model*, not just smaller
buffers.

## 3. Architecture of the edge build

### 3.1 Streaming in, events out

```
JS host                         gcf_edge.wasm (256 KB, fixed)
───────                         ─────────────────────────────
network chunk ──copy once──▶   input window (ring)  ──▶ state machine
                                                           │ manual stack [32]
                                                           ▼
objects ◀── host rebuilds ◀──  event ring (fixed)  ◀── events
```

* **Input.** `gcf_edge_feed(len)` appends a chunk (already copied into the
  window); `gcf_edge_finish()` signals end of input. GCF is line-oriented,
  so the parser only needs the current line, which may span chunk
  boundaries.
* **Output.** A tape of fixed-size events written to a ring buffer, e.g.
  16 bytes each: `kind:u8, flags:u8, depth:u8, _:u8, offset:u32, len:u32,
  aux:u32`. Kinds would cover object/section start and end, key, array start
  and end, row start, scalar (string, number, true/false/null, absent), and
  an error.
* **Backpressure.** When the event ring is full, parsing pauses and returns
  `NEED_DRAIN`; the host consumes events and calls again. The parser is
  resumable because its whole state lives in the manual stack.
* **Strings and numbers.** Events carry stream offsets. The host reads the
  text from its own copy of the chunk. Escaped strings get a flag; the host
  unescapes them with `JSON.parse` of the quoted token. Numbers are
  validated in wasm (grammar + exact int64 range) but converted by the host.
  This removes the need for float formatting tables in wasm.

### 3.2 Manual stack (no recursion)

The current recursive-descent parser becomes an explicit state machine.
`const max_depth = 32;` and a static array of frames:

| Field | Purpose |
|---|---|
| `kind` | object section, tabular, keyed map, value-grouped, expanded, attachment body, item container |
| `indent` | indentation level that owns this frame (dedent pops frames) |
| `expected` / `seen` | declared `[N]` (or deferred `[?]`) vs items seen, for count validation (§13) |
| `fields_start` / `fields_len` | slice of the shared field pool (tabular headers, inline/shared schemas) |
| `keys_start` / `keys_len` | slice of the shared fingerprint pool (duplicate-key / identity checks) |
| `row_state` | attachment markers pending in the current row (bitset index) |
| `deferred_index` | position in the `[?]` list checked against `##! summary` |

About 64 bytes per frame (*estimate*), so ~2 KB for 32 frames.

* Opening a section, attachment or nested item pushes a frame. A dedent pops
  every deeper frame (§4.1).
* Pushing frame 33 returns `nesting_too_deep`, a clean error, never a trap.
* The shadow stack can shrink to ~16 KB because nothing recurses.

### 3.3 Fixed pools and limits

Every pool is static. When one fills up, the decoder returns a new
`limit_exceeded` error and never truncates silently (SPEC §12: exceeding a
supported limit must be an error).

| Pool | Size (*estimate*) | Covers |
|---|---|---|
| Field pool | 2,048 entries × 12 B = 24 KB | ≥ 1,000 fields in one header (§12), shared by nested tabular levels |
| Fingerprint pool | 10,240 × 8 B = 80 KB | duplicate keys, keyed-map member keys, `@` identities, group values: ≥ 10,000 elements per container (§12) |
| Graph ID bitset | dense IDs up to the element limit (~1.3 KB) + small sparse table | "edge references undeclared ID" checks |

## 4. Memory budget (256 KB)

| Region | Size (*estimate*) | Notes |
|---|---|---|
| Static data | ~15 KB | 39 KB today; no JSON writer, float formatting or SHA-256 in this build |
| Shadow stack | 16 KB | no recursion |
| Input window | 72 KB | SPEC §12 requires lines of at least 65,536 bytes, plus room for the next chunk |
| Event ring | 32 KB | 2,048 events × 16 B |
| Manual stack | 2 KB | 32 frames × ~64 B |
| Field pool | 24 KB | |
| Fingerprint pool | 80 KB | |
| **Total** | **~241 KB** | ~15 KB headroom; re-check once the static data is measured |

## 5. Pending decisions (proposed, not yet confirmed)

1. **Duplicate and uniqueness checks use 64-bit fingerprints.** In streaming
   mode, earlier keys may no longer be in the input window, so the decoder
   stores a 64-bit hash per key. With 10,000 keys, the chance that two
   different keys collide is about 3×10⁻¹². The exact alternative keeps the
   whole document in memory, which limits inputs to roughly 150 KB.
2. **Pack roots and delta application stay out of the edge build.**
   `gcf-pack-root-v1` sorts every record, which does not fit in 256 KB for
   large sets. They remain in the full engine or the host.
3. **Two builds coexist.**
   * `dist/gcf.wasm`: today's full engine (value tree, JSON, pack roots,
     deltas).
   * `dist/gcf_edge.wasm`: the capped streaming decoder.

   This plan was written when the shipped module was the Zig build: both
   were to come from Zig sources selected by a comptime flag (shared scalar,
   SIMD and header code). Since the shipped codec is now hand-written WAT,
   whether the edge build is written in Zig (gcf-zig) or WAT is still open;
   [`WAT_CODEC.md`](WAT_CODEC.md) §7 notes that the WAT codec's explicit
   memory map makes it the simpler base.

## 6. Implementation steps

1. **Build target.** Add the edge build:
   `-target wasm32-freestanding -O ReleaseFast -mcpu=generic+simd128
   --initial-memory=262144 --max-memory=262144 --stack 16384`. Measure its
   static data and correct the budget in §4.
2. **ABI.** `gcf_edge_reset`, `gcf_edge_input_ptr/cap`, `gcf_edge_feed(len)`,
   `gcf_edge_finish()`, `gcf_edge_events_ptr/count`, plus the existing error
   exports (category, message, line).
3. **Parser.** State machine with the 32-frame stack and the fixed pools,
   reusing the SIMD scanners (line splitting, quote-aware delimiter search,
   UTF-8 validation that tolerates chunk boundaries).
4. **Host.** `src/host_edge.ts`: feed chunks from a `ReadableStream`, drain
   events, and rebuild the same JS values as the full engine.
5. **Tests.**
   * The whole conformance suite through the edge build (events → JS value
     → compared with the fixture), except pack-root/delta-apply operations
     (decision 2).
   * `memory.buffer.byteLength` is always exactly 262,144 and `memory.grow`
     fails.
   * Depth 32 decodes; depth 33 returns `nesting_too_deep`.
   * A 65,536-byte line, a 1,000-field header, and a 10,000-row container.
   * Inputs split into chunks at every position, including mid-line and in
     the middle of a UTF-8 character.
   * Pool exhaustion returns `limit_exceeded`.
6. **Benchmark.** Add the edge build to `bench/` (throughput and peak memory
   vs the full engine and the Blackwell TypeScript SDK).

Rough size: a second parser of ~1,500–2,000 lines of Zig, plus host code and
tests.
