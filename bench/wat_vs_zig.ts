// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// wat_vs_zig.ts — the hand-written WAT codec (dist/gcf.debug.wasm) against the
// Zig reference build (dist/gcf_zig.wasm): same ABI, same inputs, same outputs.
//
//   bun bench/wat_vs_zig.ts                 # JavaScriptCore
//   bun run bench:wat                       # JavaScriptCore, then Node (V8)
//
// Also measured when present (`zig build wasm-generic` in reference/gcf-zig):
// the equal-scope Zig builds zig-out/wasm/gcf_generic.wasm (ReleaseFast) and
// gcf_generic_small.wasm (ReleaseSmall), restricted to the same exports.
//
// Both modules are driven through their raw exports (no JS glue), so the
// numbers compare the WebAssembly code only. Every measured call is first
// checked to produce byte-identical output on both modules. Plain Node APIs
// only, so the bundled copy runs under node. Run from the project root.
import { existsSync, readdirSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { gzipSync } from "node:zlib";
import { join } from "node:path";

const root = process.cwd();
const runtime = typeof (globalThis as { Bun?: unknown }).Bun !== "undefined" ? "bun" : "node";
const engineName = runtime === "bun" ? "JavaScriptCore" : "V8";
const enc = new TextEncoder();
const dec = new TextDecoder();

type X = { memory: WebAssembly.Memory } & { [k: string]: (...a: number[]) => number };

async function load(file: string) {
  const bytes = readFileSync(join(root, file));
  const t0 = performance.now();
  const mod = await WebAssembly.compile(bytes);
  const compileMs = performance.now() - t0;
  const t1 = performance.now();
  const inst = await WebAssembly.instantiate(mod, {});
  const instantiateMs = performance.now() - t1;
  return { x: inst.exports as unknown as X, bytes: bytes.length, gzip: gzipSync(bytes, { level: 9 }).length, compileMs, instantiateMs };
}

function put(x: X, b: Uint8Array) {
  const p = x.gcf_input_alloc(b.length);
  new Uint8Array(x.memory.buffer, p, b.length).set(b);
  return b.length;
}

function output(x: X) {
  return Buffer.from(new Uint8Array(x.memory.buffer, x.gcf_output_ptr(), x.gcf_output_len())).toString("latin1");
}

/** Median and best of 9 timed batches of >= 120 ms each (ms per call). */
function time(x: X, b: Uint8Array, call: (n: number) => number) {
  const samples: number[] = [];
  for (let rep = 0; rep < 9; rep++) {
    let iters = 0;
    const t0 = performance.now();
    let t = t0;
    while (t - t0 < 120) {
      const st = call(put(x, b));
      if (st !== 0) throw new Error(`status ${st}`);
      iters++;
      t = performance.now();
    }
    samples.push((t - t0) / iters);
  }
  samples.sort((a, b) => a - b);
  return { median: samples[4], best: samples[0] };
}

const zig = await load("dist/gcf_zig.wasm");
const wat = await load("dist/gcf.debug.wasm");
// Equal-scope Zig builds (generic decode/encode exports only), from
// `zig build wasm-generic` in reference/gcf-zig; optional.
const optional = async (f: string) => (existsSync(join(root, f)) ? load(f) : null);
const zigFast = await optional("reference/gcf-zig/zig-out/wasm/gcf_generic.wasm");
const zigSmall = await optional("reference/gcf-zig/zig-out/wasm/gcf_generic_small.wasm");

const payloadDir = join(root, "bench/payloads");
const generic = readdirSync(payloadDir)
  .filter((f) => f.endsWith(".gcf"))
  .sort()
  .map((f) => ({ name: f.replace(/\.gcf$/, ""), gcf: enc.encode(readFileSync(join(payloadDir, f), "utf8")), json: enc.encode(readFileSync(join(payloadDir, f.replace(/\.gcf$/, ".json")), "utf8")) }));

type Row = { payload: string; op: string; kb: number; zigMs: number; watMs: number; ratio: number; zigGenericMs?: number; zigSmallMs?: number };
const rows: Row[] = [];
type Op = { op: string; input: "gcf" | "json"; fn: string; call: (x: X) => (n: number) => number; check: boolean; graph?: boolean };
const ops: Op[] = [
  { op: "decode (GCF -> JSON)", input: "gcf", fn: "gcf_decode", call: (x) => (n) => x.gcf_decode(n), check: true },
  { op: "decode tree only", input: "gcf", fn: "gcf_decode_tree", call: (x) => (n) => x.gcf_decode_tree(n), check: false },
  { op: "decode to tape", input: "gcf", fn: "gcf_decode_tape", call: (x) => (n) => x.gcf_decode_tape(n), check: true },
  { op: "encode (JSON -> GCF)", input: "json", fn: "gcf_encode", call: (x) => (n) => x.gcf_encode(n, 0), check: true },
  { op: "parse JSON only", input: "json", fn: "gcf_bench_parse_json", call: (x) => (n) => x.gcf_bench_parse_json(n), check: false },
];
// graph payloads: decode as above, plus the columnar decoder and the graph encoder
const graphOps: Op[] = [
  ops[0], ops[1], ops[2],
  { op: "decode graph columns", input: "gcf", fn: "gcf_decode_graph_columns", call: (x) => (n) => x.gcf_decode_graph_columns(n), check: true },
  { op: "encode graph (JSON -> GCF)", input: "json", fn: "gcf_encode_graph", call: (x) => (n) => x.gcf_encode_graph(n), check: true },
  ops[4],
];
const allOps = [...new Map([...ops, ...graphOps].map((o) => [o.op, o])).values()];
const has = (m: { x: X } | null, fn: string) => m !== null && typeof m.x[fn] === "function";

for (const p of generic) {
  for (const o of p.name.startsWith("graph") ? graphOps : ops) {
    const b = p[o.input];
    if (o.check) {
      const z = o.call(zig.x)(put(zig.x, b));
      const zo = output(zig.x);
      const w = o.call(wat.x)(put(wat.x, b));
      const wo = output(wat.x);
      if (z !== 0 || w !== 0 || zo !== wo) throw new Error(`${p.name} ${o.op}: outputs differ (status ${z}/${w})`);
    }
    const tz = time(zig.x, b, o.call(zig.x));
    const tw = time(wat.x, b, o.call(wat.x));
    const row: Row = { payload: p.name, op: o.op, kb: b.length / 1024, zigMs: tz.median, watMs: tw.median, ratio: tw.median / tz.median };
    // the equal-scope generic builds cover generic payloads and their exports only
    if (!p.name.startsWith("graph") && has(zigFast, o.fn)) row.zigGenericMs = time(zigFast!.x, b, o.call(zigFast!.x)).median;
    if (!p.name.startsWith("graph") && has(zigSmall, o.fn)) row.zigSmallMs = time(zigSmall!.x, b, o.call(zigSmall!.x)).median;
    rows.push(row);
  }
}

const pad = (s: string, n: number) => s.padEnd(n);
console.log(`\nWAT codec vs Zig build — ${runtime} (${engineName}), median ms per call; ratio < 1 means WAT is faster\n`);
const opt = (v?: number) => (v === undefined ? "-" : v.toFixed(3)).padStart(10);
console.log(pad("payload", 16), pad("operation", 26), "KB".padStart(8), "zig".padStart(9), "wat".padStart(9), "wat/zig".padStart(8), "zig-gen".padStart(10), "zig-small".padStart(10));
for (const r of rows) console.log(pad(r.payload, 16), pad(r.op, 26), r.kb.toFixed(1).padStart(8), r.zigMs.toFixed(3).padStart(9), r.watMs.toFixed(3).padStart(9), r.ratio.toFixed(2).padStart(8), opt(r.zigGenericMs), opt(r.zigSmallMs));

const geo = (op: string, large: boolean) => {
  const rs = rows.filter((r) => r.op === op && r.payload.endsWith(large ? "-large" : "-small"));
  return Math.exp(rs.reduce((s, r) => s + Math.log(r.ratio), 0) / rs.length);
};
console.log("\ngeometric mean of wat/zig:");
for (const o of allOps) console.log(`  ${pad(o.op, 26)} large ${geo(o.op, true).toFixed(2)}   small ${geo(o.op, false).toFixed(2)}`);
const geoOf = (op: string, pick: (r: Row) => number | undefined) => {
  const rs = rows.filter((r) => r.op === op && pick(r) !== undefined);
  return rs.length ? Math.exp(rs.reduce((s, r) => s + Math.log(r.watMs / pick(r)!), 0) / rs.length) : NaN;
};
if (zigFast) for (const o of ops) if (o.op !== "decode to tape") console.log(`  vs zig-gen   ${pad(o.op, 22)} ${geoOf(o.op, (r) => r.zigGenericMs).toFixed(2)}   vs zig-small ${geoOf(o.op, (r) => r.zigSmallMs).toFixed(2)}`);
console.log(`\nbinary: zig ${zig.bytes} B (gzip ${zig.gzip}), wat ${wat.bytes} B (gzip ${wat.gzip})`);
if (zigFast && zigSmall) console.log(`equal scope: zig ReleaseFast ${zigFast.bytes} B (gzip ${zigFast.gzip}), zig ReleaseSmall ${zigSmall.bytes} B (gzip ${zigSmall.gzip})`);
console.log(`compile: zig ${zig.compileMs.toFixed(2)} ms, wat ${wat.compileMs.toFixed(2)} ms; instantiate: zig ${zig.instantiateMs.toFixed(2)} ms, wat ${wat.instantiateMs.toFixed(2)} ms`);

mkdirSync(join(root, "bench/results"), { recursive: true });
const out = join(root, `bench/results/wat-vs-zig-${runtime}.json`);
writeFileSync(out, JSON.stringify({
  runtime, engine: engineName, date: new Date().toISOString(),
  binary: { zig: { bytes: zig.bytes, gzip: zig.gzip }, wat: { bytes: wat.bytes, gzip: wat.gzip },
    zigGeneric: zigFast && { bytes: zigFast.bytes, gzip: zigFast.gzip }, zigGenericSmall: zigSmall && { bytes: zigSmall.bytes, gzip: zigSmall.gzip } },
  startup: { zig: { compileMs: zig.compileMs, instantiateMs: zig.instantiateMs }, wat: { compileMs: wat.compileMs, instantiateMs: wat.instantiateMs } },
  geomeanVsEqualScope: zigFast && Object.fromEntries(ops.map((o) => [o.op, { releaseFast: geoOf(o.op, (r) => r.zigGenericMs), releaseSmall: geoOf(o.op, (r) => r.zigSmallMs) }])),
  geomean: Object.fromEntries(allOps.map((o) => [o.op, { large: geo(o.op, true), small: geo(o.op, false) }])),
  rows,
}, null, 2) + "\n");
console.log(`results: ${out}`);
