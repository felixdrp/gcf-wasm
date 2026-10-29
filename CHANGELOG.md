# Changelog

All notable changes to this project are documented here. Versions follow
[Semantic Versioning](https://semver.org); the npm package and the released
`gcf.wasm` share one version number. Each release states the
[gcf-zig](https://codeberg.org/felixdrp/gcf-zig) version it is tested against
(the `reference/gcf-zig` submodule).

## 0.2.0 — 2026-10-29

Tested against gcf-zig 0.2.0.

### Decoding streams: 3–4 times less memory
* `decode`, `decodeToJson`, `decodeToJsonBytes` and `decodeLazy` (the WAT
  exports `gcf_decode` and `gcf_decode_tape`) write a generic document
  while they parse it, instead of building the whole document as a tree
  first. Each table row is assembled, written and released. Peak memory
  for a 300,000-row table (11.6 MB of GCF): 129 → 40 MB to JSON, 220 → 50 MB
  to the lazy tape (`docs/WAT_CODEC.md` §10). Decoding on a fresh instance
  is 13–21% faster (lazy tape: 31–40%); with memory already grown, from 9%
  faster to 8% slower depending on the payload and engine.
* The output is byte-identical to before and to gcf-zig; errors keep their
  category and line.
* Floats no longer leave a scratch buffer behind in the arena (decoding and
  encoding).

### Added
* `maxRetainedMemory` option (`init(source, options)`,
  `GcfCodec.instantiate(wasm, options)`), **64 MiB by default**
  (`DEFAULT_MAX_RETAINED_MEMORY`): when a call leaves the codec's
  WebAssembly memory above the limit, a fresh instance takes over as soon
  as the call returns and the old memory is garbage collected. WebAssembly
  memory cannot shrink, so until now a single large payload kept its peak
  reserved for the life of the codec. Decoding up to about 15 MB of GCF, or
  encoding up to about 15 MB of JSON, stays below the default; above it,
  the next large call is up to about 25% slower while the memory is
  requested again. `Infinity` restores the 0.1 behaviour.
* `codec.recycle()` releases the memory on demand; `codec.memoryBytes`
  reports it.
* `init()` compiles the bundled `gcf.wasm` once; `init(undefined, options)`
  returns a new codec from that module.

### Changed
* Codecs release memory above 64 MiB by default (see above).
* The lazy-decoding tape (`gcf_decode_tape`) lists its nodes in post-order,
  children before their container, as gcf-zig now does. The format and its
  version are unchanged: readers follow node indices and the header's root
  index.
* `GcfCodec.exports` is now a getter returning the current instance's
  exports (it changes after a recycle). Read it per call rather than
  keeping it.

## 0.1.1 — 2026-10-29

Documentation only; the code and `gcf.wasm` are unchanged. Tested against
gcf-zig 0.1.0.

### Documentation
* A "Compatibility and limits" section in the README and on npm:
  constant columns need a spec 3.6.0 decoder (`@blackwell-systems/gcf`
  2.6.1 on npm predates it); `encode(value)` normalises JS values like
  `JSON.stringify`; a codec's memory keeps its peak, and how to recreate
  one.

## 0.1.0 — 2026-10-28

First public release. Implements GCF specification **v3.6.0** and passes
all 323 official conformance fixtures. Tested byte for byte against
gcf-zig 0.1.0.

### The codec
* `gcf.wasm`: a complete GCF codec written by hand in WebAssembly text
  (`src/wat/*.wat`, SIMD128, no imports), ABI version 1
  (`docs/WASM_ABI.md`). It mirrors the Zig engine of gcf-zig function for
  function:
  * strict decoding of the generic and graph profiles, deltas, the
    columnar graph output and the lazy tape;
  * every encoder: generic and graph profiles, sessions, graph and generic
    deltas (full, delta, diff, re-anchoring session), opt-in value grouping;
  * pack roots (SHA-256) and atomic delta application with root
    verification;
  * correctly rounded number conversions (Clinger, Eisel-Lemire, Ryu).
* Every error carries the spec's category (SPEC §16.5) and the line, with a
  fixed message per category; the Zig build formats messages with the
  offending values.
* Byte-identical to the Zig build in differential tests (every export,
  over 600k checks during development).
* Measured in `docs/WAT_CODEC.md`: 20–40% faster than the Zig build, and
  88 KB against 511 KB.
* `gcf_simd.wasm` and `gcf_simd.relaxed.wasm`: the hand-written SIMD
  structural indexer.

### Encoding from JS values
* Graph payloads given as JS values are written into wasm memory as columns
  (`gcf_encode_graph_cols`), skipping `JSON.stringify` and JSON parsing.
  Graph encoding from JS values went from 0.76–0.79× to 2.0–2.4× the speed
  of the TypeScript SDK on large graphs.
* Generic encoding from JS values no longer scans the JSON text for 16+
  digit integers: the module reads such tokens as doubles when the host
  says the text came from `JSON.stringify` (`gcf_encode` flags bit 1,
  `gcf_features()`). Together with a key-shape cache in the JSON reader and
  value-based constant-column detection, tabular encoding from JS values
  went from 0.85–0.93× to 1.4–1.7× the speed of the TypeScript SDK.

### Fixes
* The fallback JSON serialiser used for payloads with bigints or 16+ digit
  integers now matches `JSON.stringify`: array holes become `null` (they
  produced invalid JSON), `undefined`/function members are omitted, and
  `toJSON` is honoured.

### Packages
* **npm:** `@felixdrp/gcf-wasm`:
  * a JS/TS API with a universal loader (`init()`) for Node, Bun, Deno,
    browsers and edge runtimes;
  * a bytes-in/bytes-out API and lazy decoding;
  * streaming encoders, a `largeInt` policy and the `gcf` CLI.
* **Release assets:** `gcf.wasm` (the same module as the npm package's),
  `gcf_simd.wasm`, `gcf_simd.relaxed.wasm` and `SHA256SUMS`.
