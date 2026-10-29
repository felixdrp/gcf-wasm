# @felixdrp/gcf-wasm

Fast, strict codec for the **Graph Compact Format** (GCF v3.6.0), the
token-efficient wire format for LLM tool responses specified by
[Blackwell Systems](https://github.com/blackwell-systems/gcf). The engine is
a single dependency-free WebAssembly module (88 KB, written by hand
in WebAssembly text with 128-bit SIMD, and tested byte for byte against a
reference implementation in Zig, [gcf-zig](https://codeberg.org/felixdrp/gcf-zig)). It runs in Node, Bun, Deno, browsers and
edge runtimes.

* **Conformant.** It passes all 323 official conformance fixtures. Its
  encoder output is byte-identical to the reference encoder.
* **Fast.** Against the reference TypeScript SDK: decoding is 1.6–4.5×
  faster and encoding from JS values 1.1–2.2×. In bytes-to-bytes pipelines
  (servers), encoding is 2.0–5.0× and decoding 3.9–13.8× faster
  ([benchmark](https://github.com/felixdrp/gcf-wasm/blob/main/bench/README.md)).
* **Strict.** Every malformed payload is rejected with the spec's error
  category. Integers are exact 64-bit values, with an explicit policy for
  JavaScript's 2^53 limit.
* **Complete.** Generic and graph profiles, sessions, keyed-set deltas and
  pack roots, streaming encoders, value grouping, lazy decoding and a CLI.

This is an independent implementation, not affiliated with Blackwell
Systems.

## Install

```sh
npm install @felixdrp/gcf-wasm     # or: bun add @felixdrp/gcf-wasm / deno add npm:@felixdrp/gcf-wasm
```

## Quick start

```js
import { init } from "@felixdrp/gcf-wasm";

const gcf = await init(); // loads the bundled gcf.wasm once

const text = gcf.encode({
  users: [
    { id: 1, name: "Ada Lovelace", role: "admin" },
    { id: 2, name: "Alan Turing", role: "dev" },
  ],
});
// GCF profile=generic
// ## users [2]{id,name,role}
// 1|Ada Lovelace|admin
// 2|Alan Turing|dev

gcf.decode(text); // back to the same value
```

`init()` finds `gcf.wasm` next to the module: Node, Bun and Deno read it from
disk, and browsers and bundlers fetch it (the
`new URL("./gcf.wasm", import.meta.url)` pattern). To control loading,
pass your own `URL`, `Response`, bytes or `WebAssembly.Module`:

```js
const gcf = await init(fetch("/assets/gcf.wasm"));
```

## Highlights

```js
// Bytes in, bytes out: no JS strings in between (servers, files, sockets).
const gcfBytes = gcf.encodeJsonBytes(requestBodyBytes);
const jsonBytes = gcf.decodeToJsonBytes(gcfBytes);

// Exact key order: encode JSON text instead of a JS object.
gcf.encodeJson('{"b":1,"10":2}');

// Exact 64-bit integers.
gcf.encode({ id: 9007199254740993n });
gcf.decode(text, { largeInt: "bigint" }); // or "string" | "number"; default throws

// Graph payloads, sessions and deltas.
gcf.encodeGraph({ tool: "ctx", symbols: [/* ... */], edges: [/* ... */] });

// Read part of a large document without materialising all of it.
const doc = gcf.decodeLazy(bigText);
doc.rows[0].name;
```

Also exported: `GraphSession`, `GenericDeltaSession`,
`GenericStreamEncoder`, `GraphStreamEncoder`, `encodeGenericFull`,
`encodeGenericDiff`, `applyGenericDelta`, `applyGraphDelta`, `packRoot`,
`encodeGrouped`, `toPlain`, `GcfError`. TypeScript types are included.

The streaming encoders (`GenericStreamEncoder`, `GraphStreamEncoder`) are
the only part written in JavaScript rather than in `gcf.wasm`: they emit
text as rows arrive, and crossing into wasm for every row would cost more
than it saves. They follow the same quoting and number rules as the module,
and the tests check that the two agree.

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

## CLI

```sh
npx @felixdrp/gcf-wasm encode data.json       # JSON -> GCF
npx @felixdrp/gcf-wasm decode data.gcf        # GCF -> JSON
npx @felixdrp/gcf-wasm stats data.json        # size comparison
```

## Documentation

* [Tutorial](https://github.com/felixdrp/gcf-wasm/blob/main/docs/TUTORIAL.md)
* [Architecture](https://github.com/felixdrp/gcf-wasm/blob/main/docs/ARCHITECTURE.md)
* [Benchmarks](https://github.com/felixdrp/gcf-wasm/blob/main/bench/README.md)
* [WebAssembly ABI](https://github.com/felixdrp/gcf-wasm/blob/main/docs/WASM_ABI.md),
  for using `gcf.wasm` from other languages and runtimes
* Source: [felixdrp/gcf-wasm](https://github.com/felixdrp/gcf-wasm); Zig package and reference implementation: [felixdrp/gcf-zig](https://codeberg.org/felixdrp/gcf-zig)

## License

Apache-2.0. See `LICENSE` and `NOTICE`: GCF is specified by Dayna Blackwell /
Blackwell Systems, and parts of this package are adapted from their
gcf-typescript SDK.
