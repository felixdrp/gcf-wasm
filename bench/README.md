# Codec benchmark: our WebAssembly codec vs the Blackwell TypeScript SDK

```
bun run bench         # Bun (JavaScriptCore): decoding and encoding
bun run bench:node    # Node (V8); bundles bench/run.ts into bench/dist/run.mjs
```

By default the benchmark measures the module that the npm package and the
release ship: `dist/gcf.wasm`, the hand-written WAT codec. Set
`GCF_WASM=gcf_zig.wasm` to measure the Zig reference build of
[gcf-zig](https://codeberg.org/felixdrp/gcf-zig) instead (built from the
`reference/gcf-zig` submodule); its results
go to `bench/results/{bun,node}-zig.json`. Both modules implement the same
ABI and produce byte-identical output
([`docs/WAT_CODEC.md`](../docs/WAT_CODEC.md)).

## Setup

* **Reference:** [`gcf-typescript`](https://github.com/blackwell-systems/gcf-typescript)
  v2.7.0, commit `702a4ac` (3 Oct 2026), the first version with spec 3.6.0.
  It is cloned into `bench/vendor/gcf-typescript` and imported from source; no
  scripts from that repository are run. The npm release (2.6.1) predates
  spec 3.6.0.
* **Payloads:** `bench/payloads.ts` generates deterministic datasets and
  encodes them with the reference encoder (`encodeGeneric` / `encode`), so
  every input is canonical upstream output. The files are written to
  `bench/payloads/*.gcf` with a `manifest.json`, ready for other runners.
* **Equivalence:** before any timing, the run fails unless both
  implementations produce identical decoded output (generic payloads as
  order-preserving JSON, graphs as symbols/edges) and byte-identical encoded
  GCF for every payload.
* **Strictness:** the reference SDK rejects 63/64 `errors-v2` fixtures with the
  right category. The one miss, invalid UTF-8, can't reach a string-based API.
  Both decoders therefore do the same validation work.
* **Timing:** warm-up of at least 300 ms, then up to 1.5 s of samples. Small
  payloads are batched so each sample lasts at least 2 ms. The reported figure
  is the median.

## Variants measured

**Decoding** (MB/s refers to the GCF input):

| Variant | What it includes |
|---|---|
| `blackwell-ts (string -> JS object)` | `decodeGeneric(text)` / `decode(text)`: the SDK's public API |
| `ours wasm (string -> JS object)` | `GcfCodec.decode(text)`: UTF-8 into wasm, decode, transfer, JS objects. **This is the like-for-like comparison.** |
| `ours wasm (string -> JSON text)` | `decodeToJson(text)`: the same, without materialising JS objects |
| `ours wasm (bytes -> value tree)` | The engine alone: input already in wasm memory, no transfer |

**Encoding** (MB/s refers to the JSON source):

| Variant | What it includes |
|---|---|
| `blackwell-ts (JS value -> GCF)` | `encodeGeneric(value)` / `encode(payload)` |
| `ours wasm (JS value -> GCF)` | `GcfCodec.encode(value)` / `encodeGraph(payload)`: `JSON.stringify`, transfer, encode. **Like-for-like.** |
| `ours wasm (JSON text -> GCF)` | `encodeJson(text)`: when the JSON text already exists (an HTTP body, a file) |

Before timing, decoding must produce identical values and encoding must
produce **byte-identical GCF** in both implementations.

## Results (this container, x86_64, 3.8 GHz, 14 October 2026)

Shipped module (`gcf.wasm`, then named `gcf_wat.min.wasm`). Speed-up over the TS SDK (median; above
1 means ours is faster):

| Payload | Decode → JS object (Bun / Node) | Decode, engine only (Bun / Node) | Encode JS value (Bun / Node) | Encode JSON text (Bun / Node) |
|---|---|---|---|---|
| tabular + constant column, 1.3 MB | **3.55× / 2.82×** | 13.5× / 11.5× | **1.41× / 1.15×** | 2.11× / 2.67× |
| flattened + attachments, 0.9 MB | **2.80× / 2.55×** | 8.1× / 7.9× | **1.82× / 1.59×** | 2.52× / 2.59× |
| keyed map `[N:]`, 0.5 MB | **4.46× / 3.00×** | 15.6× / 12.9× | **1.91× / 1.39×** | 2.64× / 2.65× |
| mixed / deep nesting, 0.26 MB | **3.98× / 2.59×** | 7.9× / 8.1× | **1.75× / 2.13×** | 2.57× / 2.69× |
| quoting / Unicode, 0.7 MB | **3.56× / 2.75×** | 11.9× / 8.7× | **1.71× / 1.58×** | 2.52× / 2.71× |
| graph profile, 1 MB | **2.31× / 2.54×** | 5.0× / 6.9× | **2.09× / 2.17×** | — |

Small payloads (0.7–7 KB) follow the same pattern: decoding 1.6–4.4×;
encoding 1.1–1.9× from JS values and 1.5–3.0× from JSON text. Raw numbers
are in `bench/results/{bun,node}.json`.

Encoding from JS values used to trail the SDK on graphs (0.79× / 0.76×)
and on the tabular payload (0.85× / 0.93×). Two changes made it faster on
every payload:

* **Graphs** are written by the host straight into wasm memory as columns
  (`gcf_encode_graph_cols`).
* **Generic data** skips a host-side scan of the JSON text: the module reads
  `JSON.stringify` numbers itself (`gcf_encode` flags bit 1). The JSON
  reader also caches key shapes, and constant columns are found by
  comparing values.

Details are in [`docs/WAT_CODEC.md`](../docs/WAT_CODEC.md), sections 8 and 9.

### Summary, and the shipped module vs the Zig build

Geometric mean of the speed-up over the TS SDK across all 12 payloads:

| Operation | Bun: WAT module | Bun: Zig module | Node: WAT module | Node: Zig module |
|---|---|---|---|---|
| Decode string → JS object | **3.24×** | 2.53× | **2.52×** | 1.89× |
| Encode JS value → GCF | **1.69×** | 0.96× | **1.58×** | 0.96× |
| Encode from JSON text | **2.30×** | 1.44× | **2.51×** | 1.62× |
| Bytes → bytes encode | **3.46×** | 2.27× | **3.65×** | 2.45× |
| Bytes → bytes decode | **8.33×** | 6.06× | **7.27×** | 4.68× |

The WAT columns are from 14 October; the Zig columns from a run on
12 October with the same host and payloads. The Zig module has neither the
columnar graph input nor the JS-host number flag, so with it `encode`
still scans the JSON text and graphs go through JSON. The shipped module
improves every comparison by 28–76%.

### Bytes in, bytes out (server pipeline)

Both implementations go from UTF-8 bytes to UTF-8 bytes. The TS SDK pays
`TextDecoder` and `JSON.parse`/`stringify` around its codec. Because its
`decode` returns `Map`s, producing JSON also needs a Map-aware replacer.
Ours calls `encodeJsonBytes` / `decodeToJsonBytes`. Speed-up on large
payloads (shipped module):

| | tabular | nested | keyed | mixed | quoted | graph |
|---|---|---|---|---|---|---|
| encode, Bun / Node | 3.71× / 4.60× | 3.56× / 2.98× | 3.74× / 4.37× | 5.03× / 4.27× | 4.65× / 4.63× | 2.83× / 3.72× |
| decode, Bun / Node | 9.49× / 6.95× | 10.14× / 5.23× | 11.92× / 13.82× | 10.20× / 5.68× | 9.34× / 8.40× | 4.49× / 5.11× |

Bytes-to-bytes decoding under Node varies between runs. On 13 October the
tabular, nested and mixed payloads measured 10.3×, 8.5× and 7.6×.

### Lazy access

Decode + read part of the document (shipped module; ms):

| Payload: access | TS SDK (Bun / Node) | ours `decode` (Bun / Node) | ours `decodeLazy` (Bun / Node) |
|---|---|---|---|
| tabular-large: read the first row only | 58.2 / 72.3 | 18.9 / 24.0 | **8.8 / 10.4** |
| tabular-large: sum one field of every row | 81.7 / 73.7 | 23.1 / 25.6 | **20.7 / 22.5** |
| nested-large: count gold customers | 53.6 / 45.6 | 16.5 / 17.7 | **13.6 / 14.3** |
| graph-large: read the first symbol only | 12.1 / 12.9 | **4.6 / 5.0** | 4.8 / 5.5 |
| graph-large: sum one field of every symbol | 11.1 / 12.4 | **5.3 / 5.1** | 9.5 / 11.0 |

Lazy decoding pays off when little of a large generic document is read. For
graphs, plain `decode` with its columnar transfer is faster. Analysis in
[`docs/JS_WASM_BOUNDARY.md`](../docs/JS_WASM_BOUNDARY.md).

### Reading the numbers

* **Decoding** is 1.6–4.5× faster end to end, and 5–16× when the result can
  stay in wasm memory. Most of the end-to-end time is the host boundary
  (JSON text + `JSON.parse`), not decoding.
* **Encoding from JSON text** is 1.5–3.0× faster.
* **Encoding from JS values** is 1.1–2.2× faster on every payload. What
  remains on our side is mostly `JSON.stringify` (generic data still
  crosses as JSON text) and parsing that text in wasm. Writing generic
  values into wasm memory directly, as graphs already are, would remove
  both.

### Optimisation history

These steps were made on the Zig engine, before the hand-written WAT codec
existed; the WAT codec started from the optimised design. Its own
optimisations are described in [`docs/WAT_CODEC.md`](../docs/WAT_CODEC.md).

**Graph decoding.** In the first benchmark graphs decoded at 0.57× (Bun):

| Stage (graph-large, Bun) | Before | After | Change |
|---|---|---|---|
| Engine: build decoded graph | 7.7 ms | 2.1 ms | dense ID table; in-place field splitting; hand-rolled `@id`/score parsing (`cents / 100.0` is exact); pre-sized lists |
| Engine → JS transfer | 3.24 MB JSON | ~4× smaller columnar JSON | `gcf_decode_graph_columns` + object rebuild in `src/host.ts` (identical objects, verified) |
| **End to end** | **19.1 ms (0.57×)** | **~6 ms (2.0×)** | |

**Encoding.** The first encoder build encoded graph-large in 27 ms (0.38×).
Profiling the phases inside wasm showed that resolving edge endpoints took
16.9 ms there against ~1 ms natively. The cause was `std.mem.eql` from the
Zig standard library: on wasm32+simd128 it compiles to very slow code for
~40-byte keys, and every successful hash lookup calls it. Replacing it, and
`startsWith`, `order` and `indexOfScalar`, with word-at-a-time and bitmask
SIMD versions cut graph encoding to ~11 ms. It also sped up decoding of
keyed maps (key checks) and graphs.

Changes that also help generic payloads:
* Clinger fast path for decimal parsing, plus a shortest-decimal fast path
  for formatting. Both are bit-identical to the general algorithms, checked
  on 200k values.
* A JSON reader with shared scratch stacks and one-pass strings.
* A wasm-friendly 32-bit-hash string map.
* `encodeInto` straight into wasm memory.

## Adding another implementation (e.g. Go)

Use the same files listed in `manifest.json`: `*.gcf` for decoding, `*.json`
for encoding.
Benchmark in-process so process start-up isn't measured, and emit results in
the same JSON format as `bench/results/*.json`: `{payload, bytes, impl,
medianMs, p90Ms, samples, mbps}`. A Go runner would be a `testing.B`
benchmark or a small `main` that reads each payload, calls `gcf.Decode`, and
writes `bench/results/go.json`.
