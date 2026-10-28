// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Decoder benchmark: our WebAssembly engine vs the Blackwell TypeScript SDK.
//
// Runtime-agnostic (Bun and Node). Run from the project root:
//   bun bench/run.ts                 # Bun / JavaScriptCore
//   node bench/dist/run.mjs          # Node / V8 (bundle built by bench/run_all.ts)
//
// Every implementation decodes the same canonical payloads (bench/payloads/).
// Before timing, each implementation's output is checked against the
// reference so we never compare decoders doing different work.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { decode as tsDecodeGraph, decodeGeneric as tsDecodeGeneric, encode as tsEncodeGraph, encodeGeneric as tsEncodeGeneric } from "./vendor/gcf-typescript/src/index.ts";
import { generatePayloads, type PayloadSpec } from "./payloads.ts";
import { GcfCodec, toPlain } from "../src/host.ts";

const root = process.cwd();
const runtime = typeof (globalThis as { Bun?: unknown }).Bun !== "undefined" ? `bun ${(globalThis as any).Bun.version}` : `node ${process.version}`;
const enc = new TextEncoder();
const dec = new TextDecoder();

// ---------------------------------------------------------------------------
// Our engine, minimal portable host. Default: the module the npm package and
// the release ship (dist/gcf.wasm, the hand-written WAT codec);
// GCF_WASM=gcf_zig.wasm measures the Zig reference build instead.
// ---------------------------------------------------------------------------
type Exports = {
  memory: WebAssembly.Memory;
  gcf_input_alloc(n: number): number;
  gcf_decode(n: number): number;
  gcf_decode_tree(n: number): number;
  gcf_output_ptr(): number;
  gcf_output_len(): number;
  gcf_error_name_ptr(): number;
  gcf_error_name_len(): number;
};
const wasmFile = process.env.GCF_WASM ?? "gcf.wasm";
const wasmBytes = readFileSync(join(root, "dist", wasmFile));
const wasm = (await WebAssembly.instantiate(wasmBytes, {})).instance.exports as unknown as Exports;
// Public host API (src/host.ts): what an application would actually call.
const host = await GcfCodec.instantiate(wasmBytes);

function wasmLoad(bytes: Uint8Array): number {
  const ptr = wasm.gcf_input_alloc(bytes.length);
  new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
  return bytes.length;
}

function wasmCheck(status: number) {
  if (status !== 0) throw new Error(`wasm decode failed: ${dec.decode(new Uint8Array(wasm.memory.buffer, wasm.gcf_error_name_ptr(), wasm.gcf_error_name_len()))}`);
}

/** JS string -> UTF-8 -> wasm -> JSON text (no JS object materialisation). */
function wasmToJsonText(text: string): string {
  wasmCheck(wasm.gcf_decode(wasmLoad(enc.encode(text))));
  return dec.decode(new Uint8Array(wasm.memory.buffer, wasm.gcf_output_ptr(), wasm.gcf_output_len()));
}

// ---------------------------------------------------------------------------
// Implementations
// ---------------------------------------------------------------------------
type Prepared = { text: string; bytes: Uint8Array; json: string; spec: PayloadSpec };
type Impl = {
  name: string;
  /** Called once per payload before timing (e.g. copy input into wasm). */
  setup?(p: Prepared): void;
  run(p: Prepared): unknown;
  /** Normalised output for the equivalence check (reference only). */
  normalise?(out: unknown, p: Prepared): string;
};

/** Order-preserving JSON for Maps (the TS SDK decodes objects into Map). */
function stableJson(v: unknown): string {
  if (v instanceof Map) return `{${[...v.entries()].map(([k, x]) => `${JSON.stringify(k)}:${stableJson(x)}`).join(",")}}`;
  if (Array.isArray(v)) return `[${v.map(stableJson).join(",")}]`;
  if (v !== null && typeof v === "object") return `{${Object.entries(v).map(([k, x]) => `${JSON.stringify(k)}:${stableJson(x)}`).join(",")}}`;
  if (typeof v === "bigint") return v.toString();
  return JSON.stringify(v);
}

/** Graph results reduced to the fields both decoders expose. */
function graphCore(v: any): string {
  const syms = (v.symbols ?? []).map((s: any) => [s.qualifiedName, s.kind, s.score, s.provenance, s.distance]);
  const edges = (v.edges ?? []).map((e: any) => [e.source, e.target, e.edgeType, e.status ?? ""]);
  return JSON.stringify({ syms, edges });
}

const reference: Impl = {
  name: "blackwell-ts (string -> JS object)",
  run: (p) => (p.spec.profile === "graph" ? tsDecodeGraph(p.text) : tsDecodeGeneric(p.text)),
  normalise: (out, p) => (p.spec.profile === "graph" ? graphCore(out) : stableJson(out)),
};

const impls: Impl[] = [
  reference,
  {
    name: "ours wasm (string -> JS object)",
    run: (p) => host.decode(p.text),
  },
  {
    name: "ours wasm (string -> JSON text)",
    run: (p) => host.decodeToJson(p.text),
  },
  {
    name: "ours wasm (bytes -> value tree)",
    setup: (p) => {
      wasmLoad(p.bytes);
    },
    run: (p) => wasmCheck(wasm.gcf_decode_tree(p.bytes.length)),
  },
];

// ---------------------------------------------------------------------------
// Timing
// ---------------------------------------------------------------------------
function measure(impl: Impl, p: Prepared): { medianMs: number; p90Ms: number; samples: number } {
  impl.setup?.(p);
  // Warm-up: at least 300 ms or 30 calls, so both JITs reach steady state.
  let calls = 0;
  const w0 = performance.now();
  while (calls < 30 || performance.now() - w0 < 300) {
    impl.run(p);
    calls++;
  }
  const perCall = (performance.now() - w0) / calls;
  // Batch tiny payloads so each sample lasts >= 2 ms (timer resolution).
  const batch = Math.max(1, Math.ceil(2 / perCall));
  const samples: number[] = [];
  const t0 = performance.now();
  while (samples.length < 15 || (performance.now() - t0 < 1500 && samples.length < 400)) {
    const s = performance.now();
    for (let k = 0; k < batch; k++) impl.run(p);
    samples.push((performance.now() - s) / batch);
  }
  samples.sort((a, b) => a - b);
  return { medianMs: samples[Math.floor(samples.length / 2)], p90Ms: samples[Math.floor(samples.length * 0.9)], samples: samples.length };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const payloadDir = join(root, "bench/payloads");
const specs = generatePayloads(payloadDir);
const prepared: Prepared[] = specs.map((spec) => {
  const text = readFileSync(join(payloadDir, spec.file), "utf8");
  return { text, bytes: enc.encode(text), json: readFileSync(join(payloadDir, spec.jsonFile), "utf8"), spec };
});

console.log(`GCF codec benchmark — ${runtime} — ${new Date().toISOString()}`);
console.log("Decoding (size and MB/s refer to the GCF input)");

// Equivalence check: identical decoded output before any timing. All three
// "ours" variants run the same engine, so one comparison per payload covers
// them. Generic output is compared byte-for-byte as order-preserving JSON.
for (const p of prepared) {
  const ref = reference.normalise!(reference.run(p), p)!;
  const ours = p.spec.profile === "graph" ? graphCore(host.decode(p.text)) : wasmToJsonText(p.text);
  if (p.spec.profile === "graph" && JSON.stringify(host.decode(p.text)) !== wasmToJsonText(p.text)) {
    throw new Error(`columnar graph objects differ from gcf_decode JSON on ${p.spec.name}`);
  }
  if (ours !== ref) {
    let i = 0;
    while (i < ours.length && ours[i] === ref[i]) i++;
    throw new Error(`output differs on ${p.spec.name} at char ${i}:\n ours: ${ours.slice(Math.max(0, i - 60), i + 60)}\n  ref: ${ref.slice(Math.max(0, i - 60), i + 60)}`);
  }
}
console.log(`equivalence: all ${prepared.length} payloads decode to identical output in both implementations\n`);

type Row = { payload: string; size: string; impl: string; "median ms": string; "MB/s": string; "vs TS": string };
const rows: Row[] = [];
const results: unknown[] = [];
for (const p of prepared) {
  let refMs = 0;
  for (const impl of impls) {
    const m = measure(impl, p);
    if (impl === reference) refMs = m.medianMs;
    const mbps = p.bytes.length / 1e6 / (m.medianMs / 1e3);
    rows.push({
      payload: p.spec.name,
      size: p.bytes.length >= 1e6 ? `${(p.bytes.length / 1e6).toFixed(2)} MB` : `${(p.bytes.length / 1e3).toFixed(1)} KB`,
      impl: impl.name,
      "median ms": m.medianMs < 0.1 ? m.medianMs.toFixed(4) : m.medianMs.toFixed(3),
      "MB/s": mbps.toFixed(0),
      "vs TS": impl === reference ? "1.00x" : `${(refMs / m.medianMs).toFixed(2)}x`,
    });
    results.push({ operation: "decode", payload: p.spec.name, bytes: p.bytes.length, impl: impl.name, ...m, mbps });
  }
}
console.table(rows);

// ---------------------------------------------------------------------------
// Encoding: JS value -> GCF text
// ---------------------------------------------------------------------------
const encodeReference: Impl = {
  name: "blackwell-ts (JS value -> GCF)",
  run: (p) => (p.spec.profile === "graph" ? tsEncodeGraph(p.spec.data as never) : tsEncodeGeneric(p.spec.data)),
};
const encodeImpls: Impl[] = [
  encodeReference,
  {
    name: "ours wasm (JS value -> GCF)",
    run: (p) => (p.spec.profile === "graph" ? host.encodeGraph(p.spec.data as never) : host.encode(p.spec.data)),
  },
  {
    // Engine + transfer only: the JSON text already exists (e.g. an HTTP body).
    name: "ours wasm (JSON text -> GCF)",
    run: (p) => (p.spec.profile === "graph" ? host.encodeGraph(p.spec.data as never) : host.encodeJson(p.json)),
  },
];

for (const p of prepared) {
  const want = encodeReference.run(p) as string;
  for (const impl of encodeImpls.slice(1)) {
    const got = impl.run(p) as string;
    if (got !== want) {
      let i = 0;
      while (i < got.length && got[i] === want[i]) i++;
      throw new Error(`${impl.name} encodes ${p.spec.name} differently at byte ${i}:\n ours: ${JSON.stringify(got.slice(Math.max(0, i - 60), i + 60))}\n  ref: ${JSON.stringify(want.slice(Math.max(0, i - 60), i + 60))}`);
    }
  }
}
console.log(`\nequivalence: all ${prepared.length} payloads encode to byte-identical GCF in both implementations\n`);

const encodeRows: Row[] = [];
for (const p of prepared) {
  let refMs = 0;
  for (const impl of encodeImpls) {
    if (p.spec.profile === "graph" && impl.name.includes("JSON text")) continue; // graph API takes objects only
    const m = measure(impl, p);
    if (impl === encodeReference) refMs = m.medianMs;
    const mbps = p.spec.jsonBytes / 1e6 / (m.medianMs / 1e3);
    encodeRows.push({
      payload: p.spec.name,
      size: p.spec.jsonBytes >= 1e6 ? `${(p.spec.jsonBytes / 1e6).toFixed(2)} MB` : `${(p.spec.jsonBytes / 1e3).toFixed(1)} KB`,
      impl: impl.name,
      "median ms": m.medianMs < 0.1 ? m.medianMs.toFixed(4) : m.medianMs.toFixed(3),
      "MB/s": mbps.toFixed(0),
      "vs TS": impl === encodeReference ? "1.00x" : `${(refMs / m.medianMs).toFixed(2)}x`,
    });
    results.push({ operation: "encode", payload: p.spec.name, bytes: p.spec.jsonBytes, impl: impl.name, ...m, mbps });
  }
}
console.log("Encoding (size and MB/s refer to the JSON source)");
console.table(encodeRows);

// ---------------------------------------------------------------------------
// Bytes in, bytes out: the server pipeline (request body -> response body).
// The TS SDK works on strings, so it pays TextDecoder/TextEncoder and
// JSON.parse/stringify around its codec; ours stays in bytes.
// ---------------------------------------------------------------------------
const td = new TextDecoder();
const te = new TextEncoder();
const mapsToObjects = (_k: string, v: unknown) => (v instanceof Map ? Object.fromEntries(v) : v);
type BytesCase = Prepared & { jsonBytes: Uint8Array };
const bytesCases: BytesCase[] = prepared.map((p) => ({ ...p, jsonBytes: te.encode(p.json) }));
const bytesImpls: { name: string; op: "encode" | "decode"; run: (p: BytesCase) => Uint8Array }[] = [
  {
    name: "blackwell-ts encode (bytes -> bytes)",
    op: "encode",
    run: (p) => te.encode(p.spec.profile === "graph" ? tsEncodeGraph(JSON.parse(td.decode(p.jsonBytes))) : tsEncodeGeneric(JSON.parse(td.decode(p.jsonBytes)))),
  },
  { name: "ours encodeJsonBytes", op: "encode", run: (p) => host.encodeJsonBytes(p.jsonBytes, { profile: p.spec.profile }) },
  {
    name: "blackwell-ts decode (bytes -> JSON bytes)",
    op: "decode",
    run: (p) => te.encode(JSON.stringify(p.spec.profile === "graph" ? tsDecodeGraph(td.decode(p.bytes)) : tsDecodeGeneric(td.decode(p.bytes)), mapsToObjects)),
  },
  { name: "ours decodeToJsonBytes", op: "decode", run: (p) => host.decodeToJsonBytes(p.bytes) },
];
for (const p of bytesCases) {
  const [tsEnc, ourEnc, tsDec, ourDec] = bytesImpls.map((i) => i.run(p));
  if (td.decode(tsEnc) !== td.decode(ourEnc)) throw new Error(`bytes encode differs on ${p.spec.name}`);
  const a = JSON.parse(td.decode(tsDec));
  const b = JSON.parse(td.decode(ourDec));
  const same = p.spec.profile === "graph" ? graphCore(a) === graphCore(b) : JSON.stringify(a) === JSON.stringify(b);
  if (!same) throw new Error(`bytes decode differs on ${p.spec.name}`);
}
console.log(`\nequivalence: bytes pipelines agree on all ${bytesCases.length} payloads\n`);
const bytesRows: Row[] = [];
for (const p of bytesCases) {
  for (const op of ["encode", "decode"] as const) {
    let refMs = 0;
    for (const impl of bytesImpls.filter((i) => i.op === op)) {
      const asImpl: Impl = { name: impl.name, run: () => impl.run(p) };
      const m = measure(asImpl, p);
      if (impl.name.startsWith("blackwell")) refMs = m.medianMs;
      const size = op === "encode" ? p.jsonBytes.length : p.bytes.length;
      const mbps = size / 1e6 / (m.medianMs / 1e3);
      bytesRows.push({
        payload: p.spec.name,
        size: size >= 1e6 ? `${(size / 1e6).toFixed(2)} MB` : `${(size / 1e3).toFixed(1)} KB`,
        impl: impl.name,
        "median ms": m.medianMs < 0.1 ? m.medianMs.toFixed(4) : m.medianMs.toFixed(3),
        "MB/s": mbps.toFixed(0),
        "vs TS": impl.name.startsWith("blackwell") ? "1.00x" : `${(refMs / m.medianMs).toFixed(2)}x`,
      });
      results.push({ operation: `bytes-${op}`, payload: p.spec.name, bytes: size, impl: impl.name, ...m, mbps });
    }
  }
}
console.log("Bytes in, bytes out (server pipeline)");
console.table(bytesRows);

// ---------------------------------------------------------------------------
// Lazy access: decode + read part of the document (docs/JS_WASM_BOUNDARY.md)
// ---------------------------------------------------------------------------
// The TS SDK decodes objects into Map, so its accessors use Map.get.
type Access = { name: string; ts: (v: any) => unknown; js: (v: any) => unknown };
const accessByPayload: Record<string, Access[]> = {
  "tabular-large": [
    { name: "sum one field of every row", ts: (v) => v.get("employees").reduce((a: number, r: any) => a + r.get("salary"), 0), js: (v) => v.employees.reduce((a: number, r: any) => a + r.salary, 0) },
    { name: "read the first row only", ts: (v) => v.get("employees")[0].get("name"), js: (v) => v.employees[0].name },
  ],
  "nested-large": [
    { name: "count gold customers", ts: (v) => v.get("orders").filter((o: any) => o.get("customer").get("tier") === "gold").length, js: (v) => v.orders.filter((o: any) => o.customer.tier === "gold").length },
  ],
  "graph-large": [
    { name: "sum one field of every symbol", ts: (v) => v.symbols.reduce((a: number, s: any) => a + s.score, 0), js: (v) => v.symbols.reduce((a: number, s: any) => a + s.score, 0) },
    { name: "read the first symbol only", ts: (v) => v.symbols[0].qualifiedName, js: (v) => v.symbols[0].qualifiedName },
  ],
};
const lazyRows: Row[] = [];
for (const p of prepared) {
  for (const acc of accessByPayload[p.spec.name] ?? []) {
    const tsDecode = (t: string) => (p.spec.profile === "graph" ? tsDecodeGraph(t) : tsDecodeGeneric(t));
    const variants: Impl[] = [
      { name: "blackwell-ts decode + read", run: (q) => acc.ts(tsDecode(q.text)) },
      { name: "ours decode + read", run: (q) => acc.js(host.decode(q.text)) },
      { name: "ours decodeLazy + read", run: (q) => acc.js(host.decodeLazy(q.text)) },
    ];
    const want = variants[0].run(p);
    for (const v of variants) {
      const got = v.run(p);
      if (typeof want === "number" ? Math.abs((got as number) - want) > 1e-6 * Math.abs(want) : got !== want) throw new Error(`${v.name} disagrees on ${p.spec.name}/${acc.name}: ${got} vs ${want}`);
    }
    let refMs = 0;
    for (const v of variants) {
      const m = measure(v, p);
      if (v === variants[0]) refMs = m.medianMs;
      lazyRows.push({ payload: `${p.spec.name}: ${acc.name}`, size: `${(p.bytes.length / 1e6).toFixed(2)} MB`, impl: v.name, "median ms": m.medianMs.toFixed(3), "MB/s": (p.bytes.length / 1e6 / (m.medianMs / 1e3)).toFixed(0), "vs TS": v === variants[0] ? "1.00x" : `${(refMs / m.medianMs).toFixed(2)}x` });
      results.push({ operation: "lazy", payload: p.spec.name, access: acc.name, impl: v.name, ...m });
    }
  }
  // Worst case for lazy decoding: materialise everything.
  if (p.spec.name === "tabular-large" || p.spec.name === "graph-large") {
    const variants: Impl[] = [
      { name: "ours decode (full)", run: (q) => host.decode(q.text) },
      { name: "ours decodeLazy + toPlain (full)", run: (q) => toPlain(host.decodeLazy(q.text)) },
      { name: "ours decodeLazy + JSON.stringify (full)", run: (q) => JSON.stringify(host.decodeLazy(q.text)) },
    ];
    let refMs = 0;
    for (const v of variants) {
      const m = measure(v, p);
      if (v === variants[0]) refMs = m.medianMs;
      lazyRows.push({ payload: `${p.spec.name}: materialise everything`, size: `${(p.bytes.length / 1e6).toFixed(2)} MB`, impl: v.name, "median ms": m.medianMs.toFixed(3), "MB/s": (p.bytes.length / 1e6 / (m.medianMs / 1e3)).toFixed(0), "vs TS": `${(refMs / m.medianMs).toFixed(2)}x vs eager` });
    }
  }
}
console.log("Lazy access (decode + read part of the document)");
console.table(lazyRows);

const outDir = join(root, "bench/results");
mkdirSync(outDir, { recursive: true });
const tag = runtime.split(" ")[0] + (wasmFile === "gcf_zig.wasm" ? "-zig" : "");
writeFileSync(join(outDir, `${tag}.json`), JSON.stringify({ runtime, module: wasmFile, date: new Date().toISOString(), results }, null, 2) + "\n");
console.log(`results written to bench/results/${tag}.json`);
