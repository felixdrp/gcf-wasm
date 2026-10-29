# gcf.wasm — WebAssembly ABI (version 1)

`gcf.wasm` is the GCF codec as published in the releases and in the npm
package. It is the hand-written WAT codec (`src/wat/*.wat`, built as
`dist/gcf.wasm`, without debug names). The Zig build of
[gcf-zig](https://codeberg.org/felixdrp/gcf-zig) (`zig build wasm`, root
`src/wasm.zig`; `dist/gcf_zig.wasm` in a checkout of this repository)
implements the same ABI, byte for byte, and is the reference implementation
(see [`WAT_CODEC.md`](WAT_CODEC.md)). This document is the contract for using
either **directly**
from any WebAssembly runtime: browsers, Node, Bun, Deno, Cloudflare Workers,
wasmtime, wasmer, wazero (Go), wasmtime-py, and others. JavaScript users
normally use the [`@felixdrp/gcf-wasm`](../npm/README.md) wrapper instead.

## Module properties

* **No imports.** The module is `wasm32-freestanding` and needs nothing from
  the host. Instantiate it with an empty import object.
* **Features.** It requires the SIMD128 proposal, which is standard in all
  current engines. It does not need threads or relaxed SIMD.
* **Memory.** One exported memory, `memory`. The module grows it on demand
  with `memory.grow`, so **re-read the memory buffer after every call**: a
  grow detaches previous views in JS.
* **State.** Single-threaded: use one instance per thread or worker. Each
  call resets the module's arena.
* **ABI version.** `gcf_abi_version()` returns `1`. It changes on any
  incompatible change to this document.

## Calling protocol

Every operation follows the same four steps; all integers are `u32`:

1. `ptr = gcf_input_alloc(len)`: resets the arena and reserves `len` input
   bytes. A return of 0 means out of memory.
2. Copy the input (UTF-8 bytes) to `memory[ptr .. ptr+len]`.
3. `status = gcf_<operation>(len[, flags])`: 0 is success, anything else is
   an error code (see the table below).
4. Read the result:
   * **On success:** `memory[gcf_output_ptr() .. +gcf_output_len()]`.
   * **On error:** `gcf_error_name_ptr()/_len()` (the category, e.g.
     `count_mismatch`), `gcf_error_message_ptr()/_len()` and
     `gcf_error_line()` (1-based; 0 when not applicable).

Input, output and error strings are valid **only until the next
`gcf_input_alloc`**: copy anything you keep.

A complete, tested host in about 25 lines of plain JavaScript:
[`examples/wasm/minimal.mjs`](../examples/wasm/minimal.mjs).

## Operations

### Decoding (input: GCF text)

| Export | Output |
|---|---|
| `gcf_decode(len)` | JSON text of the decoded value. Integers are exact (int64 digits). |
| `gcf_decode_graph_columns(len)` | Compact columnar JSON for non-delta graph payloads: `{tool, tokenBudget, tokensUsed, packRoot, names, kinds, provs, types, statuses, k, p, s, d, es, et, ty, st, references?}`. Symbol `i` is `{names[i], kinds[k[i]], s[i], provs[p[i]], d[i]}`; edge `j` is `{names[es[j]], names[et[j]], types[ty[j]], statuses[st[j]]}`. |
| `gcf_decode_tape(len)` | Binary tape for lazy decoding. Layout documented in [`src/wat/12_tape.wat`](../src/wat/12_tape.wat) and at `TapeWriter` in gcf-zig's `src/gcf.zig`. Nodes are in post-order (children before their container, the root last); read them through the header's root index and the child indices. |
| `gcf_output_unsafe_ints()` | 1 if the last JSON output contains an integer beyond ±(2^53−1). JS hosts use it to apply a large-integer policy. |

Decoded shapes:
* **Generic payload:** the JSON value itself.
* **Generic delta:** `{delta, key, baseRoot, newRoot, added, changed, removed}`.
* **Graph payload:** `{tool, tokenBudget, tokensUsed, packRoot, symbols:[{qualifiedName, kind, score, provenance, distance}], edges:[{source, target, edgeType, status}]}`,
  plus `session`, `unchanged` and `references` when present.
* **Graph delta:** `{delta, baseRoot, newRoot, removed, added, edgesRemoved, edgesAdded}`.

### Encoding (input: JSON text; output: GCF text)

| Export | Input |
|---|---|
| `gcf_encode(len, flags)` | Any JSON value → generic profile. `flags` bit 0 = `no_flatten`; bit 1 = JS-host numbers (WAT module only, see the extensions below). Duplicate keys and integers outside int64 are errors. |
| `gcf_encode_graph(len)` | `{tool?, tokenBudget?, tokensUsed?, packRoot?, symbols, edges}` |
| `gcf_encode_graph_session(len)` | `{payload, known: {qualifiedName: id}, next}`. Known symbols become bare references; the host keeps the session map. |
| `gcf_encode_graph_delta(len)` | `{tool?, baseRoot, newRoot, removed, added, removedEdges, addedEdges, deltaTokens?, fullTokens?}` |
| `gcf_encode_generic_full(len)` | `{set: {name?, key, fields, rows}, tool?}` |
| `gcf_encode_generic_delta(len)` | `{tool?, key, fields, baseRoot, newRoot, added?, changed?, removed?, deltaTokens?, fullTokens?}` |
| `gcf_generic_diff(len)` | `{base: set, next: set, tool?, deltaTokens?, fullTokens?}` → delta GCF |
| `gcf_encode_grouped(len)` | `{data, keyField, groupField}` → value-grouped GCF |

**No streaming encoder.** Every export encodes a complete document in one
call. The streaming encoders of the npm package (`GenericStreamEncoder`,
`GraphStreamEncoder`, with `[?]` counts and a `##! summary` trailer) are
written in JavaScript in [`src/host.ts`](../src/host.ts), because a call
into wasm per row would cost more than it saves. Hosts in other languages
either collect the rows and call `gcf_encode` / `gcf_encode_graph`, or
port those two classes and their scalar helpers (`needsQuote`,
`formatScalar`, `formatScore`, about 230 lines in all). The quoting rule is
SPEC §2.4, and numbers use the canonical formatting of SPEC §2.3.1.

### Pack roots and deltas (input: JSON)

| Export | Input → output |
|---|---|
| `gcf_pack_root(len)` | `{symbols, edges}` or `{fields?, rows}` → `sha256:<hex>` |
| `gcf_delta_decode_apply(len)` | `{wire, base: {key, fields, rows}, expectedNewRoot?}` → new root (verified) |
| `gcf_delta_verify(len)` | `{base, delta, expectedNewRoot?}` (delta as JSON) → new root |
| `gcf_graph_delta_apply(len)` | `{wire, base: {symbols, edges}}` → `{"root": ..., "snapshot": {...}}` |

### Diagnostics

`gcf_abi_version()`, `gcf_memory_pages()`, `gcf_arena_high_water()`,
`gcf_decode_tree(len)` (decode without output, for benchmarks),
`gcf_bench_parse_json(len)`, `gcf_scan_structural(len)`,
`gcf_scan_structural_scalar(len)`,
`gcf_scan_structural_positions(len, out_ptr, cap)`.

### Extensions (WAT module only)

`gcf_features()` returns a bitmask of the optional features below. The Zig
build does not export it; a host that finds no `gcf_features` must assume
none.

| Bit | Feature |
|---|---|
| 0 | `gcf_encode_graph_cols` |
| 1 | `gcf_encode` flags bit 1: JS-host numbers |

**JS-host numbers.** A JavaScript number is a double, but `JSON.stringify`
writes an integral double of magnitude ≥ 2^53 as plain digits, which the
reader would take as an exact int64 (or reject beyond int64). With flags
bit 1 set, an integer token of magnitude ≥ 2^53 is read as the double it
came from. Smaller integers stay exact integers. Hosts set the bit only for
text produced by `JSON.stringify` on a JS value, never for JSON text from
elsewhere. This spares the host from scanning the text for such tokens.

### Extension: columnar graph input

`gcf_encode_graph_cols(len)` encodes a graph payload that the host has
written as columns instead of JSON text. This saves `JSON.stringify` on the
host and JSON parsing in wasm. The output is the same as
`gcf_encode_graph`. Only the hand-written WAT module (`gcf.wasm` as
published) exports it, so hosts must feature-detect it; `src/host.ts` does,
and falls back to `gcf_encode_graph`.

Input layout (little-endian; the input buffer starts 8-byte aligned):

| Offset | Field |
|---|---|
| 0 | `u32` magic `0x47464347` ("GCFG") |
| 4 | `u32` number of symbols S |
| 8 | `u32` number of edges E |
| 12 | `u32` offset of the string area (= 48 + 40·S + 32·E) |
| 16 | `u32, u32` tool (offset, length in the string area) |
| 24 | `u32, u32` packRoot (offset, length) |
| 32 | `f64` tokenBudget |
| 40 | `f64` tokensUsed |
| 48 | S symbols of 40 bytes: `f64` score, `f64` distance, then (offset, length) of qualifiedName, kind, provenance |
| 48 + 40·S | E edges of 32 bytes: (offset, length) of source, target, edgeType, status |
| string area | UTF-8 bytes up to `len` |

How field values are read:

* A missing or non-string field is the empty string.
* A missing or non-finite number is 0.
* tokenBudget, tokensUsed and distance are truncated to integers, as the
  JSON path does with a double.
* Offsets outside the string area give `invalid_input`.

## Error codes

Prefer the **name** (`gcf_error_name_*`), which matches the spec's
categories and the conformance fixtures. Numbers are stable within an ABI
version: new codes are appended, never reordered.

| # | name | # | name | # | name |
|---|---|---|---|---|---|
| 1 | missing_header | 17 | row_width_mismatch | 33 | duplicate_group |
| 2 | missing_profile | 18 | count_mismatch | 34 | invalid_node_line |
| 3 | unknown_profile | 19 | invalid_count | 35 | invalid_symbol_id |
| 4 | malformed_header_field | 20 | tab_indentation | 36 | invalid_score |
| 5 | duplicate_header_field | 21 | invalid_indent | 37 | invalid_edge_syntax |
| 6 | unterminated_quote | 22 | invalid_item_id | 38 | unknown_edge_reference |
| 7 | invalid_escape | 23 | orphan_attachment | 39 | unknown_section |
| 8 | trailing_characters | 24 | orphan_inline_attachment | 40 | malformed_delta |
| 9 | invalid_missing | 25 | missing_attachment | 41 | root_mismatch |
| 10 | invalid_attachment_marker | 26 | duplicate_attachment | 42 | delta_conflict |
| 11 | invalid_surrogate | 27 | inline_width_mismatch | 43 | invalid_json |
| 12 | invalid_utf8 | 28 | invalid_key | 44 | invalid_input |
| 13 | invalid_control_character | 29 | invalid_line | 45 | nesting_too_deep |
| 14 | out_of_range | 30 | invalid_const_value | 46 | out_of_memory |
| 15 | duplicate_key | 31 | no_bare_column | | |
| 16 | duplicate_field_name | 32 | invalid_group_header | | |

## Companion module

`gcf_simd.wasm` (and `gcf_simd.relaxed.wasm`) is the separate hand-written
structural indexer. Its exports are `count_structural`, `index_structural`,
`next_structural`, `classify_byte`, `calibrate`, `ensure_capacity` and
`input_base`, documented line by line in
[`src/gcf_simd.wat`](../src/gcf_simd.wat). It is not needed for encoding or
decoding. Both variants are attached to each release next to `gcf.wasm`.
