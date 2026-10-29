# gcf-wasm

A fast, strict codec for the **Graph Compact Format** (GCF v3.6.0), the
token-efficient wire format for LLM tool responses specified by
[Blackwell Systems](https://github.com/blackwell-systems/gcf). The engine is
a single 88 KB WebAssembly module written by hand in WebAssembly text, with
128-bit SIMD and no imports, plus a zero-dependency JavaScript API.

| For | Package | Install |
|---|---|---|
| **Node, Bun, Deno, browsers, edge** | [`@felixdrp/gcf-wasm`](npm/README.md) on npm | `npm install @felixdrp/gcf-wasm` |
| **Any WebAssembly runtime** | `gcf.wasm` (release assets) | wasmtime, wasmer, wazero, … ([ABI](docs/WASM_ABI.md)) |
| **Zig** | [gcf-zig](https://codeberg.org/felixdrp/gcf-zig) | `zig fetch --save git+https://codeberg.org/felixdrp/gcf-zig#v0.1.0` |

The codec mirrors [gcf-zig](https://codeberg.org/felixdrp/gcf-zig), the
reference implementation in Zig, function for function, and is tested byte
for byte against it. Against the Zig build it is 20–40% faster and 5.6×
smaller ([comparison](docs/WAT_CODEC.md)).

This is an independent implementation, not affiliated with Blackwell
Systems.

## Why this implementation

* **Conformant.** It passes all **323/323** official conformance fixtures.
  The encoder is byte-for-byte identical to the reference encoder, and
  every export is compared byte for byte with the Zig reference build.
* **Fast.** Against the reference TypeScript SDK:
  * decoding is 1.6–4.5× faster and encoding from JS values 1.1–2.2×;
  * in bytes-to-bytes pipelines (servers), encoding is 2.0–5.0× and decoding
    3.9–13.8× faster;
  * the SIMD structural scanner runs at ~13–19 GB/s.

  See [benchmarks](bench/README.md).
* **Strict and exact.** Every malformed payload is rejected with the spec's
  error category. Integers are exact 64-bit values, with an explicit policy
  for JavaScript's 2^53 limit.
* **Complete.** Generic and graph profiles, sessions, keyed-set deltas and
  pack roots, streaming encoders, value grouping, lazy decoding, and a CLI.
* **Dependency-free.** The wasm module imports nothing; the JS API has no
  dependencies.

Everything runs in `gcf.wasm` except the streaming encoders
(`GenericStreamEncoder`, `GraphStreamEncoder`), which are written in
JavaScript in [`src/host.ts`](src/host.ts). They emit text as rows arrive,
and crossing into wasm for every row would cost more than it saves. They
use the same quoting and number rules as the module, and the tests check
that the two agree. The wasm ABI therefore has no streaming encoder (see
[`docs/WASM_ABI.md`](docs/WASM_ABI.md)).

## JavaScript / TypeScript

```js
import { init } from "@felixdrp/gcf-wasm";

const gcf = await init();
const text = gcf.encode({ users: [{ id: 1, name: "Ada" }] });
gcf.decode(text);
```

Start with the [tutorial](docs/TUTORIAL.md). Every example in it is a
tested file under [`examples/`](examples).

## Compatibility and limits

* **Spec 3.6.0 output.** The encoder factors constant columns
  (`## users [3]{id,name=Ada}`), as SPEC v3.6.0 §7.4.7 requires, byte for
  byte like Blackwell's gcf-typescript 2.7.0. Decoders written for older
  versions of the spec cannot read it: `@blackwell-systems/gcf` 2.6.1, the
  latest on npm at the time of writing, predates spec 3.6.0 and fails with
  `invalid field name: name=Ada`. Check the version of the decoder at the
  other end.
* **JS values are normalised like `JSON.stringify`.** `encode(value)`
  serialises with `JSON.stringify` semantics, the host-value normalisation
  that SPEC §2.3.2 allows: `undefined` and functions are omitted, `NaN` and
  `±Infinity` become null, array holes become null, `toJSON` is honoured
  (so a `Date` becomes its ISO string), and a `Map` or `Set` becomes `{}`.
  Normalise such values yourself if they matter. For exact key order
  (numeric-looking keys), encode JSON text with `encodeJson`.
* **Memory is released above 64 MiB.** Each codec has one WebAssembly
  memory that grows to the largest payload it has handled, and WebAssembly
  memory cannot shrink: a 300,000-row payload needs about 150 MB. By
  default, a call that leaves more than 64 MiB reserved is followed by a
  fresh instance, switched in as soon as the call returns, and the old
  memory is garbage collected. Payloads up to about 5 MB of GCF (10 MB of
  JSON) never reach the limit. Above it, the next large call is about
  15–30% slower while the memory is requested again; if you handle such
  payloads continuously, raise the limit with
  `init(undefined, { maxRetainedMemory: 512 << 20 })` (bytes) or pass
  `Infinity` to keep the memory. `codec.memoryBytes` reports the current
  size and `await codec.recycle()` releases it on demand. The limit bounds
  what stays reserved between calls, not the peak during a call.
* **Streaming encoders run in JavaScript** (see above).

## WebAssembly from other languages

`gcf.wasm` has no imports and exposes a small C-style ABI: allocate input,
copy bytes, call, read the output or the error. See
[`docs/WASM_ABI.md`](docs/WASM_ABI.md) and the 25-line raw host in
[`examples/wasm/minimal.mjs`](examples/wasm/minimal.mjs).

## Repository layout

| Path | Contents |
|---|---|
| `src/wat/` | The codec, hand-written in WAT (`dist/gcf.wasm`) |
| `src/gcf_simd.wat` | Hand-written WAT structural indexer, commented line by line |
| `src/host.ts`, `src/index.ts`, `src/cli.ts` | JavaScript API, npm entry with universal loader, CLI |
| `npm/` | npm package (built by `bun run build:npm`) |
| `reference/gcf-zig/` | [gcf-zig](https://codeberg.org/felixdrp/gcf-zig) as a git submodule: the Zig reference build the codec is tested against |
| `test/` | Conformance suite runner, encoder/boundary property tests, differential tests against Zig, performance thresholds, tutorial sync |
| `bench/` | Benchmark against the reference TypeScript SDK, and against the Zig build |
| `docs/` | Tutorial, architecture, WASM ABI, JS⇄wasm boundary study, WAT-vs-Zig comparison, plans, the original brief |

## Development

Requirements: [Bun](https://bun.sh). Node is also used by some tests and
benchmarks. The differential tests against the Zig reference also need
[Zig](https://ziglang.org) ≥ 0.17 and the submodule.

```sh
git clone --recurse-submodules https://github.com/felixdrp/gcf-wasm.git
bun install
git clone --depth 1 https://github.com/blackwell-systems/gcf.git vendor/gcf   # conformance fixtures
bun run test          # build everything, run all test suites
bun run test:oracle   # byte-for-byte comparison with the Zig reference build
bun run build:npm     # build the npm package into npm/
bun run bench         # benchmark (needs bench/vendor/gcf-typescript, see bench/README.md)
```

Without the submodule or Zig, `bun run test` skips the differential tests
with a notice; everything else runs. The scripts are documented in
`package.json`, through the `"//<script>"` keys.

Spec changes go into gcf-zig first, then into the WAT here, with
`bun run test:oracle` as the gate.

## Documentation

* [Tutorial](docs/TUTORIAL.md): using the codec, with runnable examples
* [Architecture](docs/ARCHITECTURE.md): modules, build, SIMD indexer, conformance, performance
* [WASM ABI](docs/WASM_ABI.md): using `gcf.wasm` directly
* [Hand-written WAT codec](docs/WAT_CODEC.md): design and measurements against the Zig build
* [JS ⇄ wasm boundary study](docs/JS_WASM_BOUNDARY.md): costs, techniques, standards outlook
* [Option B plan](docs/OPTION_B_PLAN.md): constrained-memory (256 KB) build
* [Original brief](docs/BRIEF.md)
* [Publishing guide](docs/PUBLISHING.md)
* [Changelog](CHANGELOG.md)

## License

[Apache-2.0](LICENSE), the same license as the GCF specification and its
reference SDKs. See [`NOTICE`](NOTICE): GCF is specified by Dayna Blackwell
/ Blackwell Systems, and parts of this project are adapted from their
gcf-typescript SDK.
