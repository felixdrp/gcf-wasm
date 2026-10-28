# The JS ⇄ WebAssembly boundary: costs, options and outlook

Study of October 2026. The question it answers: can we reduce, or eliminate,
the time spent moving data between JavaScript and the WebAssembly engine?

**Conclusion.** Eliminating it is not possible today, nor in the near term
for a linear-memory toolchain like Zig. Of the two techniques this study
recommended, both now implemented (section 4):

* **The byte-level API is a large win:** 2–3.6× faster encoding and 3–7.8×
  faster decoding than the TypeScript SDK for bytes-to-bytes pipelines.
* **Lazy decoding is a modest, situational win:** ~1.8× when only a small
  part of a large document is read.

The standards worth watching are JS String Builtins and WasmGC with Custom
Descriptors, but both need a GC-capable toolchain for the parts that touch
JS objects.

## 1. What the boundary actually costs (measured)

All figures are on this project's payloads in Bun (x86_64, 3.8 GHz); see
[`bench/README.md`](../bench/README.md).

| Operation | Total | Copying bytes | Changing representation |
|---|---|---|---|
| Decode tabular-large (1.3 MB) to JS objects | ~20 ms | negligible | ~14 ms: JSON writer in wasm, `TextDecoder`, `JSON.parse`. The engine itself takes ~6 ms. |
| Encode graph-large (3 MB JSON) from JS objects | ~15 ms | 0.15 ms (memcpy of 3 MB) | ~6.5 ms: `JSON.stringify` plus parsing that JSON in wasm. The engine itself takes ~8 ms. |

**Copying bytes is nearly free; changing representation is what costs.** JS
values are UTF-16 strings and objects on a garbage-collected heap, while
wasm linear memory holds plain bytes. Every crossing of structured data
means serialising on one side and parsing on the other. A 2026 write-up on a
Rust JSON parser compiled to wasm reached the same conclusion: the boundary
crossings, not the Rust code, were the bottleneck.

## 2. Techniques available today

### 2.1 Byte-level API (implemented, see 4.1)

When data comes from or goes to the network or a file, it already *is*
bytes. Passing bytes in and getting bytes out avoids four conversions:
`TextEncoder`, `TextDecoder`, `JSON.stringify` and `JSON.parse`. For
example: HTTP request body → GCF bytes → `Response`, or GCF bytes → JSON
bytes forwarded to another service. This is the case where wasm wins most
clearly, because a JS encoder must always build JS strings. See
`encodeJsonBytes` / `decodeToJsonBytes` in [`src/host.ts`](../src/host.ts).

### 2.2 Lazy (on-demand) decoding (implemented, see 4.2)

Instead of materialising every object, the engine writes a compact binary
*tape* (numbers in binary, strings in a byte pool). JS converts only the
values that are actually read, as simdjson's On-Demand API does. When a
consumer reads part of the data (a few fields per row, a filter, a lookup),
most of the conversion cost disappears. See `decodeLazy` in
[`src/host.ts`](../src/host.ts).

### 2.3 Compact transfer formats and batching (already used)

* **Columnar transfer.** Graph decoding already sends each string once, with
  edges as indices, which makes the JSON ~4× smaller than the spec-shaped
  output.
* **Batching.** One call per document, never one per field. Measurements in
  other projects show that calling `TextDecoder.decode` once per string is a
  classic bottleneck (wasm-bindgen does it; sledgehammer batches it). For
  short strings, a JS-side decoder beats `TextDecoder` because the native
  call has a fixed cost.

### 2.4 What does not help here

* **`SharedArrayBuffer` / shared memory.** It shares bytes across threads
  without copying, but conversion to JS objects still happens.
* **Reading streams straight into wasm memory.** BYOB readers transfer the
  view's buffer, and wasm memory buffers are not transferable, so engines
  reject it; the Web Platform Tests check for that rejection. `fetch` bodies
  are not BYOB streams either. A separate JS buffer plus one copy is
  required, but as measured above, that copy is cheap.

## 3. Standards outlook

| Proposal | Status (Oct 2026) | Relevance to this project |
|---|---|---|
| **JS String Builtins**: wasm creates and reads JS strings directly (`wasm:js-string`) | Phase 4; shipped in Chrome and Firefox. Safari 26.2 per one source (unverified). Node 24+ enabled by default per a third-party note (unverified) | Low for now. It works on UTF-16 code units via WasmGC `(array i16)`, not on linear memory or UTF-8, and Zig cannot emit GC types. A WAT glue layer (like Module A) could use it to avoid `TextDecoder` calls, but conversion to objects remains. |
| **WasmGC + Custom Descriptors**: wasm GC structs with prototypes and methods callable from JS | Phase 3; Chrome experiment (core part) since Aug 2025 | Potentially high: decoding could return live wasm objects without `JSON.parse`. Field access is through methods, though, and it needs a GC-capable language for that layer, not Zig. |
| **Resizable wasm memory buffers** (`Memory.prototype.toResizableBuffer`) | Shipped in Firefox; spec text under revision | Minor: views no longer detach on `memory.grow`. Convenience, not speed. |
| **BYOB into wasm memory** | Not possible; only a speculative idea (pausing memory via immutable ArrayBuffers) | None today. |
| **Mapping external buffers into linear memory** | No formal proposal found; only a Node hack (`buffer-tie`, memfd aliasing) that its author calls "horrible" | None. |

**Watch list:** WasmGC Custom Descriptors, for returning objects without
serialisation, and JS String Builtins, for string-heavy glue.

## 4. Results of the implementation (October 2026)

### 4.1 Bytes in, bytes out

Speed-up against the TypeScript SDK doing the same pipeline
(`TextDecoder` → `JSON.parse` → encode → `TextEncoder`, and the reverse for
decoding); large payloads, see [`bench/README.md`](../bench/README.md):

| | tabular | nested | keyed | mixed | quoted | graph |
|---|---|---|---|---|---|---|
| encode, Bun | 1.96× | 2.64× | 2.31× | 3.64× | 2.80× | 2.21× |
| encode, Node | 2.41× | 2.66× | 3.12× | 2.95× | 2.94× | 2.62× |
| decode, Bun | 7.30× | 7.46× | 7.76× | 7.43× | 6.51× | 3.81× |
| decode, Node | 6.59× | 5.20× | 6.63× | 6.48× | 5.32× | 2.92× |

This confirms the measurement in section 1: once no JS strings are
involved, the boundary costs only a memcpy. Graphs, which were *slower* than
the TypeScript SDK when encoding from JS objects (0.7×), become 2.2–2.6×
faster from bytes.

### 4.2 Lazy decoding

Decode + read, tabular-large (1.3 MB, 20,000 rows), Bun:

| Access pattern | TS SDK | `decode` | `decodeLazy` |
|---|---|---|---|
| read the first row only | 66.7 ms | 22.4 ms | **12.5 ms** |
| filter on a nested field (nested-large) | 52.8 ms | 20.2 ms | 16.7 ms |
| sum one field of every row | 70.4 ms | 23.2 ms | 21.4 ms |
| graph-large: read the first symbol | 11.9 ms | **6.4 ms** | 8.8 ms |

What the numbers show:

* **The floor is the engine.** The whole document is still parsed in wasm
  (~6 ms here) and written to the tape before anything is read, so lazy
  decoding saves only the JS-side conversion of the values that are never
  touched. The next step would be *lazy parsing*: wasm indexes rows and
  decodes them on demand. GCF's line structure makes that feasible.
* **Graphs: use `decode`.** Its columnar transfer is already cheaper than
  the generic tape.
* **Avoid `JSON.stringify` on lazy values:** going through Proxy traps for
  every value is ~5× slower than `decode`. Use `toPlain` instead.
* **Binary tape vs JSON as the eager transfer.** `toPlain(decodeLazy(x))` is
  1.09–1.21× faster than `decode` on large arrays of records, but 0.72× on
  keyed maps with many distinct keys and slower on small documents.
  Writing the tape in wasm costs the same as writing JSON. So JSON stays the
  default transfer.

## 5. Sources

* [WebAssembly/js-string-builtins](https://github.com/WebAssembly/js-string-builtins)
* [Intent to Ship: WebAssembly JS String Builtins (Chromium)](https://groups.google.com/a/chromium.org/g/blink-dev/c/zww0CT9PRVw/m/YmtNkC4jAQAJ)
* [W3C TAG review #940](https://github.com/w3ctag/design-reviews/issues/940)
* [MDN: WebAssembly JavaScript builtins](https://developer.mozilla.org/en-US/docs/WebAssembly/JavaScript_builtins)
* [MoonBit: JS String Builtins](https://moonbitlang.com/blog/js-string-builtins)
* [State of WebAssembly 2026](https://devnewsletter.com/p/state-of-webassembly-2026/)
* [Platform.uno: State of WebAssembly 2024–2025](https://platform.uno/blog/state-of-webassembly-2024-2025/)
* [WebKit bug 316494 (intoCharCodeArray)](https://bugs.webkit.org/show_bug.cgi?id=316494)
* [WebAssembly/custom-descriptors](https://github.com/WebAssembly/custom-descriptors)
* [Intent to Experiment: WebAssembly Custom Descriptors](https://groups.google.com/a/chromium.org/g/blink-dev/c/_uPKlWwz_Lw/m/8qu70HJPCgAJ)
* [WebAssembly/proposals](https://github.com/webassembly/proposals)
* [TC39 resizable ArrayBuffer](https://github.com/tc39/proposal-resizablearraybuffer)
* [WebAssembly spec PR #1961 (toResizableBuffer)](https://github.com/WebAssembly/spec/pull/1961/files)
* [Firefox bug 2021136](https://bugzilla.mozilla.org/show_bug.cgi?id=2021136)
* [MDN: ReadableStreamBYOBReader.read()](https://developer.mozilla.org/docs/Web/API/ReadableStreamBYOBReader/read)
* [MDN: Using readable byte streams](https://developer.mozilla.org/en-US/docs/Web/API/Streams_API/Using_readable_byte_streams)
* [whatwg/streams discussion, 2025](https://lists.w3.org/Archives/Public/public-webapps-github/2025Feb/0400.html)
* [buffer-tie (npm)](https://www.npmjs.com/package/buffer-tie)
* [Memory grow and ArrayBuffers (Red Badger)](https://awesome.red-badger.com/chriswhealy/memory-grow-and-arraybuffers)
* [msgpack-javascript PR #34 (TextDecoder vs WASM)](https://github.com/msgpack/msgpack-javascript/pull/34)
* [sledgehammer crate](https://docs.rs/sledgehammer)
* [Rust WASM vs TypeScript performance (2026)](https://www.kunalganglani.com/blog/rust-wasm-vs-typescript-performance.md)
