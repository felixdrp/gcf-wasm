# gcf-wasm: architecture

A SIMD WebAssembly codec (decoder and encoder) for the **Graph Compact
Format v3.6.0** ([spec](../vendor/gcf/SPEC.md), Blackwell Systems,
Apache-2.0), written by hand in WebAssembly text, with a JavaScript API. How
to *use* it is covered in [`TUTORIAL.md`](TUTORIAL.md); this document covers
how it is built.

The codec mirrors the Zig engine of
[gcf-zig](https://codeberg.org/felixdrp/gcf-zig) function for function. gcf-zig
is the reference implementation: spec changes land there first, then here,
and this repository tests every export byte for byte against it
(`reference/gcf-zig`, a git submodule). The engine's design (memory model,
pipeline, bounded recursion, numeric domain, deltas, encoder) and the spec
judgement calls are documented in gcf-zig's
[`ARCHITECTURE.md`](https://codeberg.org/felixdrp/gcf-zig/src/branch/main/docs/ARCHITECTURE.md);
what is specific to the WAT codec is in [`WAT_CODEC.md`](WAT_CODEC.md).

| Module | File | Role |
|---|---|---|
| A | `src/gcf_simd.wat` | Hand-written WAT structural indexer (nibble-table SIMD classification, `i8x16.bitmask` + `i32.ctz`) with line-by-line stack comments |
| B | `src/wat/*.wat` | The codec (`dist/gcf.wasm`): decoder, encoders, pack roots, deltas, lazy tape. Same ABI as gcf-zig's `gcf.wasm`, byte-identical output ([`WAT_CODEC.md`](WAT_CODEC.md), [`WASM_ABI.md`](WASM_ABI.md)) |
| — | `src/host.ts` | JS API: `GcfCodec` (decode/encode/deltas, bytes API, lazy decoding), sessions, streaming encoders, `largeInt` policy |
| — | `src/index.ts`, `src/cli.ts`, `bin/gcf.ts` | npm entry with universal `init()` loader; CLI (`encode` / `decode` / `stats`) |
| — | `npm/` | The `@felixdrp/gcf-wasm` package (`bun run build:npm`; ships `dist/gcf.wasm`) |
| C | `test/gcf_compliance.test.ts` | `bun:test` harness: all official conformance fixtures, SIMD cross-validation, host API, robustness |
| C | `test/gcf_encoder.test.ts`, `test/gcf_boundary.test.ts`, `test/gcf_performance.test.ts`, `test/tutorial.test.ts` | Encoder properties, bytes API and lazy decoding, FUTURE_OPTION A thresholds, tutorial ⇄ examples sync |
| C | `test/gcf_wat.test.ts` | Every export compared byte for byte with the Zig reference build (`dist/gcf_zig.wasm`), number conversions against JS, SHA-256 against node:crypto |

```
bun install          # wabt (WAT -> wasm compiler, used only at build time)
bun run test         # builds all modules, runs every test file
bun run test:conformance / bun run test:perf / bun run test:oracle
bun run bench        # codec benchmark vs the Blackwell TypeScript SDK
bun run tutorial     # refresh docs/TUTORIAL.md from examples/*.ts
```

The conformance fixtures are the upstream repository cloned into `vendor/gcf`
(`git clone --depth 1 https://github.com/blackwell-systems/gcf.git vendor/gcf`);
set `GCF_FIXTURES` to point elsewhere.

## Build

`scripts/build.ts` assembles every module into `dist/` with wabt:

| File | Source |
|---|---|
| `dist/gcf.wasm` | `src/wat/*.wat` concatenated into one module, without the name section: the module npm and the releases ship |
| `dist/gcf.debug.wasm` | The same module with function names (readable traps and profiles) |
| `dist/gcf_simd.wasm`, `dist/gcf_simd.relaxed.wasm` | `src/gcf_simd.wat` (Module A, two builds) |
| `dist/gcf_zig.wasm` | The Zig reference build, `zig build wasm` in `reference/gcf-zig`. Only for the differential tests and benchmarks; skipped, with a notice, when the submodule or Zig is missing |

The modules are `wasm32` with SIMD128 and import nothing; the harness
asserts this and instantiates them with plain `WebAssembly.instantiate`.

## Module A: the `.wat` indexer

The GCF structural alphabet is `LF " # , : = @ [ ] ^ { | } ~` (14 bytes).
Instead of 14 `i8x16.eq` + 13 `v128.or`, each 16-byte block is classified with
two `i8x16.swizzle` table lookups:

```
class = LO[byte & 0x0F] & HI[(byte >> 4) & 0x0F]   ; structural iff class != 0
mask  = i8x16.bitmask(i8x16.ne(class, 0))
```

The high nibble is computed with a 16-bit shift plus mask
(`i16x8.shr_u` + `v128.and`). `i8x16.shr_u` has no x86 equivalent and is
emulated more expensively by both engines.

The tables (one 16-byte data segment each) are chosen so that every
`(high nibble, low nibble)` pair in the alphabet shares a bit and no other
pair does. High nibbles 8-F map to 0, so non-ASCII bytes never match. The
harness verifies all 256 byte values in all 16 lane positions against a
scalar oracle.

* **`count_structural`** (classification only) keeps the tables in v128
  locals and processes 4 blocks per iteration. It never leaves the vector
  unit: `i8x16.eq(class, 0)` is −1 in non-structural lanes, `i8x16.sub` adds
  it into 16 byte-wide counters, and these are widened and summed every 252
  blocks.
* **`index_structural`** extracts positions with `i32.ctz` /
  `mask &= mask - 1`. It writes them in groups of four unconditionally (the
  simdjson "flatten bits" idea), so there is one predictable branch per four
  hits instead of a per-hit loop exit. Callers provide room for `len + 8`
  entries.
* **Tail.** The final `len % 16` bytes go through a scalar classifier that
  uses the same tables, so nothing is read past `ptr + len`.
* **`calibrate(n, k, m)`** runs a chain of 16 dependent 1-cycle add/xor ops
  per iteration. The host uses it to estimate the effective clock for the
  cycles-per-block budget, since WebAssembly cannot read the cycle counter.

**Two builds from one source.** `dist/gcf_simd.wasm` uses baseline SIMD128.
`dist/gcf_simd.relaxed.wasm` replaces every `i8x16.swizzle ;; @relaxed` with
`i8x16.relaxed_swizzle`. Those swizzles only ever see indices 0–15, where
relaxed and strict swizzle are defined to agree, so the results are identical.
Hosts load the relaxed build when `WebAssembly.validate` accepts it (Bun and
Node both do). The harness runs the 256-value × 16-lane check and the
random-buffer checks against whichever build is loaded.

Exports: `count_structural`, `index_structural`, `next_structural`,
`classify_byte`, `calibrate`, `ensure_capacity`, `input_base`, `memory`.

## Module C: conformance harness

Fixtures are dispatched on their explicit `operation` field, as the suite
README requires.

| Operations | What runs |
|---|---|
| `decode`, `error`, `roundtrip-wire`, `pack-root`, `generic-pack-root`, `generic-delta-verify`, `generic-delta-decode`, `delta` (apply), `delta-verify` | Full decode-side contract |
| `encode`, `roundtrip`, `encode-error`, `session`, `generic-delta`, `generic-delta-session`, `delta` (encode), `graph-stream-encode` | Byte-exact encoder output. Wherever a wire is present, `decode(expected wire)` must also reproduce the input |

Encoder inputs are taken as the raw JSON text of the fixture's `input`
member, so integer-like keys keep their order (JS objects would reorder
them).

Comparison rules:
* **Generic results** are compared structurally and order-sensitively. Key
  order is relaxed only where a fixture cannot pin it:
  * expectations whose keys are sorted (generated from unordered maps);
  * keys containing `>`, which travel as per-row attachments whose position
    the spec leaves open.

  Six fixtures depend on this; all other fixtures pass with strict key order.
* **Graph decode results** are compared as a subset, because the fixtures list
  only the fields they pin.
* **Graph encode fixtures** are compared as sets with a ±0.005 score
  tolerance, because encoders reorder symbols and round scores to two
  decimals.

Current result: **323 / 323 fixtures pass, none skipped.**

## Performance and FUTURE_OPTION A

`test/gcf_performance.test.ts` asserts the FUTURE_OPTION A thresholds. Every
check runs twice: in-process (Bun → JavaScriptCore) and in a Node child
process (V8, via `node --experimental-strip-types test/lib/perf.ts`).
`GCF_PERF_ASSERT=0` turns the assertions into a report.

Measured on 28 October 2026 with the shipped codec (`dist/gcf.wasm`), Bun
1.4.4 and Node 26.12.1:

| Threshold | Measured on | Bun / JSC | Node / V8 |
|---|---|---|---|
| ≥ 1.5 GB/s | indexer count / indexer index / codec scan (`gcf_scan_structural`), 16 MiB of realistic GCF | 13.5 / 6.2 / 10.7 GB/s ✓ | 15.8 / 5.9 / 9.4 GB/s ✓ |
| ≤ 3 cycles per 16-byte block | indexer classification (`count_structural`), 1 MiB cache-resident | **3.59 ✗** (expected failure) | 2.70 ✓ |
| < 2 % jitter | 10,000 continuous iterations of the compliance suite (304 wires), robust CV of 100 batches | 0.57 % ✓ | 1.04 % ✓ |

Earlier runs, with the Zig build as the codec, measured its scan at 3.6
(Bun) and 2.6 GB/s (Node); the indexer figures vary by a few GB/s between
runs.

Notes:
* **Clock.** It comes from the `calibrate` chain (3.77–3.78 GHz here).
  `/proc/cpuinfo` reports the momentary frequency (400–3800 MHz), which is
  useless for this.
* **Cycles budget.** It applies to classification, which is what the
  tokenizer does per block. Writing positions costs extra per structural byte
  (GCF is ~20% structural, about 3 hits per block). `index_structural` runs at
  ~9.5 cycles/block, down from ~26 before the rewrite, and is reported, not
  asserted.
* **JSC miss.** Bun's JavaScriptCore runs the same 9 SIMD instructions per
  block at ~3.5 cycles where V8 needs ~2.7. Isolated micro-benchmarks put the
  JSC floor for this instruction mix at ~3.46 cycles/block. The test is marked
  `test.failing`, so it stays visible and bun:test flags it as soon as it
  starts passing.
* **Jitter metric.** A robust CV (1.4826 × MAD / median): on this shared
  machine, OS preemption hits a few batches per run. Plain CV (1.3–4.3%) and
  5%-trimmed CV (0.4–1.5%, failing 2% intermittently) track that noise; the
  robust CV does not. All three are printed.
* **Full decoder.** Measured, not asserted: ~190–210 MB/s on mixed generic
  payloads and ~540–555 MB/s on graphs (value tree). Against the Blackwell
  TypeScript SDK, decoding to JS objects is 1.6–4.5× faster end to end
  (`bench/README.md`).

## Not yet activated

* **FUTURE_OPTION B** (4-page cap, zero-copy window, manual nesting stack):
  not applied yet. Decided: the manual stack will hold **32 levels**, the
  SPEC §12 minimum (about 2 KB of the 256 KB budget), instead of the 16 in
  the original brief. Full plan: [`OPTION_B_PLAN.md`](OPTION_B_PLAN.md).

