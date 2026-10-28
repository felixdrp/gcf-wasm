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
