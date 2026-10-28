// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// perf.ts — runtime-agnostic performance measurements (FUTURE_OPTION A).
//
// Used in-process by test/gcf_performance.test.ts (Bun / JavaScriptCore) and
// as a CLI under Node (V8), which prints one JSON report on stdout:
//
//   node --experimental-strip-types test/lib/perf.ts
//
// Nothing here asserts; the test file applies the thresholds.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const dist = join(projectRoot, "dist");

export type PerfReport = {
  runtime: string;
  simdVariant: "relaxed" | "baseline";
  clockGHz: number;
  scan: {
    bufferMB: number;
    structuralRatio: number;
    watCountGBs: number;
    watIndexGBs: number;
    codecScanGBs: number;
    scalarGBs: number;
  };
  cycles: { bufferKB: number; classifyPerBlock: number; indexPerBlock: number };
  jitter: { iterations: number; batches: number; batchSize: number; fixtures: number; meanMs: number; robustCvPct: number; cvTrimmedPct: number; cvRawPct: number; madPct: number; p99OverP50: number };
  decode: { name: string; bytes: number; mbps: number }[];
};

const now = () => performance.now();

/** Median wall time (ms) of `fn` over `n` runs after `warm` warm-up runs. */
function median(fn: () => void, n = 21, warm = 3): number {
  for (let i = 0; i < warm; i++) fn();
  const t: number[] = [];
  for (let i = 0; i < n; i++) {
    const s = now();
    fn();
    t.push(now() - s);
  }
  t.sort((a, b) => a - b);
  return t[n >> 1];
}

function stats(a: number[]) {
  const m = a.reduce((p, c) => p + c, 0) / a.length;
  const sd = Math.sqrt(a.reduce((p, c) => p + (c - m) ** 2, 0) / a.length);
  return { mean: m, cv: (100 * sd) / m };
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/** Realistic generic + graph GCF text (attachments, keyed map, tabular, graph). */
export function sampleGcf(scale: number): string {
  let s = `GCF profile=generic\n## orders [${scale}]{id,"customer>name","customer>tier",items,status}\n`;
  for (let i = 0; i < scale; i++) {
    s += `@${i} ORD-${i}|Customer ${i}|${i % 2 ? "gold" : "basic"}|^|shipped\n.items [2]{sku,qty,price}\n    SKU-${i}-A|${(i % 5) + 1}|19.99\n    SKU-${i}-B|1|"5,00"\n`;
  }
  s += `## servers [${scale}:]{key,cpu,mem,status}\n`;
  for (let i = 0; i < scale; i++) s += `srv-${i}|${i % 100}|${(i * 3) % 100}|ok\n`;
  s += `## employees [${scale}]{id,name,email,department,salary}\n`;
  for (let i = 0; i < scale; i++) s += `${i}|Employee ${i}|user${i}@example.com|Dept ${i % 7}|${50000 + ((i * 7919) % 90000)}\n`;
  return s;
}

export function sampleGraph(nodes: number): string {
  let s = `GCF profile=graph tool=bench symbols=${nodes} edges=${nodes - 1}\n## targets\n`;
  for (let i = 0; i < nodes; i++) s += `@${i} fn github.com/org/repo/pkg${i % 50}.Func${i} 0.${String(99 - (i % 90)).padStart(2, "0")} lsp_resolved\n`;
  s += `## edges [${nodes - 1}]\n`;
  for (let i = 1; i < nodes; i++) s += `@${i - 1}<@${i} calls\n`;
  return s;
}

function fill(target: Uint8Array, unit: Uint8Array) {
  for (let o = 0; o < target.length; o += unit.length) target.set(unit.subarray(0, Math.min(unit.length, target.length - o)), o);
}

/** Every GCF wire in the official suite (decode, error, encode, ... inputs). */
export function suiteWires(fixtureRoot = join(projectRoot, "vendor/gcf/tests/conformance")): Uint8Array[] {
  const walk = (d: string): string[] =>
    readdirSync(d).flatMap((f) => {
      const p = join(d, f);
      return statSync(p).isDirectory() ? walk(p) : p.endsWith(".json") ? [p] : [];
    });
  const enc = new TextEncoder();
  const out: Uint8Array[] = [];
  for (const f of walk(fixtureRoot).sort()) {
    const j = JSON.parse(readFileSync(f, "utf8"));
    for (const w of [j.input, j.expected, j.input?.wire]) if (typeof w === "string" && w.startsWith("GCF")) out.push(enc.encode(w));
    if (typeof j.inputBase64 === "string") out.push(new Uint8Array(Buffer.from(j.inputBase64, "base64")));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

async function instantiate(file: string): Promise<any> {
  return (await WebAssembly.instantiate(readFileSync(join(dist, file)), {})).instance.exports;
}

export async function loadModules() {
  const relaxedBytes = readFileSync(join(dist, "gcf_simd.relaxed.wasm"));
  const relaxed = WebAssembly.validate(relaxedBytes);
  return {
    simd: await instantiate(relaxed ? "gcf_simd.relaxed.wasm" : "gcf_simd.wasm"),
    simdVariant: (relaxed ? "relaxed" : "baseline") as "relaxed" | "baseline",
    engine: await instantiate("gcf.wasm"),
  };
}

/**
 * Effective core clock (Hz). The .wat `calibrate` export runs a chain of 16
 * dependent 1-cycle-latency ops per iteration, so ops / time = cycles / time.
 * /proc/cpuinfo is not used: it reports the momentary (often idle) frequency,
 * not the boosted clock the benchmark actually runs at.
 */
export function calibrateHz(simd: any): number {
  const n = 20_000_000;
  return (16 * n) / (median(() => simd.calibrate(n, 3, 5), 7, 1) / 1e3);
}

// ---------------------------------------------------------------------------
// Measurements
// ---------------------------------------------------------------------------

export async function runPerf(): Promise<PerfReport> {
  const { simd, simdVariant, engine } = await loadModules();
  const hz = calibrateHz(simd);
  const unit = new TextEncoder().encode(sampleGcf(2000) + sampleGraph(2000).slice("GCF profile=graph".length));

  // ---- scanner throughput: 16 MiB (larger than typical L2/L3) ------------
  const bigLen = 16 << 20;
  const base = simd.input_base();
  simd.ensure_capacity(bigLen + (bigLen + 8) * 4 + 64);
  const big = new Uint8Array(simd.memory.buffer, base, bigLen);
  fill(big, unit);
  const out = base + bigLen + 16;
  const structural = simd.count_structural(base, bigLen);
  const tCount = median(() => simd.count_structural(base, bigLen));
  const tIndex = median(() => simd.index_structural(base, bigLen, out));

  const zptr = engine.gcf_input_alloc(bigLen);
  fill(new Uint8Array(engine.memory.buffer, zptr, bigLen), unit);
  if (engine.gcf_scan_structural(bigLen) !== structural) throw new Error("codec and indexer structural counts disagree");
  const tCodec = median(() => engine.gcf_scan_structural(bigLen));
  const tScalar = median(() => engine.gcf_scan_structural_scalar(bigLen), 5, 1);
  const gbs = (t: number) => bigLen / 1e9 / (t / 1e3);

  // ---- cycles per 16-byte block: 1 MiB, cache-resident -------------------
  // The budget is about compute per block, so the buffer is sized to stay in
  // cache; the 16 MiB figures above include memory bandwidth.
  const smallLen = 1 << 20;
  const reps = 16;
  const tCountSmall = median(() => {
    for (let r = 0; r < reps; r++) simd.count_structural(base, smallLen);
  }) / reps;
  const tIndexSmall = median(() => {
    for (let r = 0; r < reps; r++) simd.index_structural(base, smallLen, out);
  }) / reps;
  const perBlock = (t: number) => (hz * (t / 1e3)) / (smallLen / 16);

  // ---- jitter: 10,000 continuous iterations of the compliance suite ------
  const wires = suiteWires();
  let mem = new Uint8Array(engine.memory.buffer);
  const pass = () => {
    for (const w of wires) {
      const p = engine.gcf_input_alloc(w.length);
      if (mem.buffer !== engine.memory.buffer) mem = new Uint8Array(engine.memory.buffer); // refresh only after memory.grow
      mem.set(w, p);
      engine.gcf_decode(w.length);
    }
  };
  for (let i = 0; i < 500; i++) pass();
  const iterations = 10_000;
  const batchSize = 100;
  const per: number[] = [];
  const batches: number[] = [];
  for (let b = 0; b < iterations / batchSize; b++) {
    const s0 = now();
    for (let i = 0; i < batchSize; i++) {
      const s = now();
      pass();
      per.push(now() - s);
    }
    batches.push(now() - s0);
  }
  const sortedBatches = [...batches].sort((a, b) => a - b);
  const trim = Math.floor(batches.length * 0.05);
  const med = sortedBatches[batches.length >> 1];
  const mad = [...batches.map((v) => Math.abs(v - med))].sort((a, b) => a - b)[batches.length >> 1];
  const sortedPer = [...per].sort((a, b) => a - b);

  // ---- full decoder throughput (reported, not asserted) ------------------
  const decode: PerfReport["decode"] = [];
  for (const [name, text] of [
    ["generic mixed", sampleGcf(4000)],
    ["graph", sampleGraph(10000)],
  ] as const) {
    const bytes = new TextEncoder().encode(text);
    const p = engine.gcf_input_alloc(bytes.length);
    new Uint8Array(engine.memory.buffer, p, bytes.length).set(bytes);
    const t = median(() => engine.gcf_decode_tree(bytes.length), 21, 3);
    decode.push({ name: `${name} (value tree)`, bytes: bytes.length, mbps: bytes.length / 1e6 / (t / 1e3) });
  }

  const runtime = typeof (globalThis as any).Bun !== "undefined" ? `bun ${(globalThis as any).Bun.version} (JavaScriptCore)` : `node ${process.version} (V8)`;
  return {
    runtime,
    simdVariant,
    clockGHz: hz / 1e9,
    scan: { bufferMB: bigLen / (1 << 20), structuralRatio: structural / bigLen, watCountGBs: gbs(tCount), watIndexGBs: gbs(tIndex), codecScanGBs: gbs(tCodec), scalarGBs: gbs(tScalar) },
    cycles: { bufferKB: smallLen >> 10, classifyPerBlock: perBlock(tCountSmall), indexPerBlock: perBlock(tIndexSmall) },
    jitter: {
      iterations,
      batches: batches.length,
      batchSize,
      fixtures: wires.length,
      meanMs: stats(per).mean,
      // 1.4826 * MAD / median: the standard outlier-resistant estimate of the
      // coefficient of variation (equals the CV for normally distributed data).
      robustCvPct: (1.4826 * 100 * mad) / med,
      cvTrimmedPct: stats(sortedBatches.slice(trim, batches.length - trim)).cv,
      cvRawPct: stats(batches).cv,
      madPct: (100 * mad) / med,
      p99OverP50: sortedPer[Math.floor(per.length * 0.99)] / sortedPer[per.length >> 1],
    },
    decode,
  };
}

// CLI: `node --experimental-strip-types test/lib/perf.ts` prints the report.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  console.log(JSON.stringify(await runPerf()));
}
