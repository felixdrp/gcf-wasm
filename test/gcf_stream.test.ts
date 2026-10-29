// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// gcf_stream.test.ts — the streaming decoder. gcf_decode and gcf_decode_tape
// write a generic document while they parse it, and release each table row
// once it is written; the result must still be byte-identical to the Zig
// reference (which builds the whole tree first), errors included. These
// documents are large enough to cross every growth path (output buffer,
// tape region, child-index stack) and mix rows that allocate (attachments,
// flattening, escaped strings, identity keys) with rows that do not.
//
// The memory bounds at the end keep the point of streaming: peak arena use a
// small multiple of the input, not the size of a full value tree.
import { beforeAll, describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { gen, genScalar, rng, TRICKY } from "./lib/gen";

const dist = join(import.meta.dir, "..", "dist");
const haveOracle = existsSync(join(dist, "gcf_zig.wasm"));
if (!haveOracle) {
  if (process.env.GCF_REQUIRE_ORACLE === "1") throw new Error("dist/gcf_zig.wasm missing: git submodule update --init, then bun run build");
  console.warn("gcf_stream.test.ts: differential tests skipped (no dist/gcf_zig.wasm)");
}

type X = { memory: WebAssembly.Memory } & { [k: string]: (...a: number[]) => number };
const enc = new TextEncoder();
const dec = new TextDecoder();
let wat: X;
let zig: X;
beforeAll(async () => {
  wat = (await WebAssembly.instantiate(readFileSync(join(dist, "gcf.wasm")), {})).instance.exports as unknown as X;
  if (haveOracle) zig = (await WebAssembly.instantiate(readFileSync(join(dist, "gcf_zig.wasm")), {})).instance.exports as unknown as X;
});

function call(x: X, fn: string, input: string | Uint8Array, flag?: number): string {
  const b = typeof input === "string" ? enc.encode(input) : input;
  const p = x.gcf_input_alloc(b.length);
  new Uint8Array(x.memory.buffer, p, b.length).set(b);
  const st = flag === undefined ? x[fn](b.length) : x[fn](b.length, flag);
  if (st) return `E ${dec.decode(new Uint8Array(x.memory.buffer, x.gcf_error_name_ptr(), x.gcf_error_name_len()))} @${x.gcf_error_line()}`;
  const out = new Uint8Array(x.memory.buffer, x.gcf_output_ptr(), x.gcf_output_len());
  return fn === "gcf_decode_tape" ? `O ${Buffer.from(out).toString("hex")}` : `O ${x.gcf_output_unsafe_ints()} ${dec.decode(out)}`;
}

/** Both decoders of the WAT module against Zig; returns whether the wire decoded. */
function same(wire: string): boolean {
  let ok = true;
  for (const fn of ["gcf_decode", "gcf_decode_tape"]) {
    const a = call(zig, fn, wire);
    const b = call(wat, fn, wire);
    if (a !== b) {
      const at = [...a].findIndex((c, i) => c !== b[i]);
      throw new Error(`${fn} differs (wire ${wire.length} bytes) at ${at}\n  zig: ${JSON.stringify(a.slice(Math.max(0, at - 80), at + 120))}\n  wat: ${JSON.stringify(b.slice(Math.max(0, at - 80), at + 120))}\n  wire head: ${JSON.stringify(wire.slice(0, 400))}`);
    }
    ok &&= a.startsWith("O");
  }
  return ok;
}

/** Encode a JS value with the Zig encoder (the reference wire). */
function wireOf(value: unknown): string {
  const out = call(zig, "gcf_encode", JSON.stringify(value), 0);
  if (!out.startsWith("O ")) throw new Error(`encode failed: ${out}`);
  return out.slice(4);
}

/** A row of a large table: nested values, escapes, constant and absent cells. */
function row(r: () => number, i: number, keys: string[]): Record<string, unknown> {
  const o: Record<string, unknown> = {};
  for (const k of keys) {
    const p = r();
    if (p < 0.08) continue; // absent
    if (k === "id") o[k] = i;
    else if (k === "kind") o[k] = "fixed"; // a constant column unless rows drop it
    else if (p < 0.55) o[k] = genScalar(r);
    else if (p < 0.7) o[k] = TRICKY[Math.floor(r() * TRICKY.length)];
    else o[k] = gen(r, 2);
  }
  return o;
}

/** `## x [N]` and `.field [N]` headers become `[?]`, with the summary trailer. */
function deferCounts(wire: string): string {
  const counts: string[] = [];
  const body = wire.replace(/^(\s*(?:## [^\n\[]*|\.[^\s]+ ))\[(\d+)\]/gm, (_m, head: string, n: string) => {
    counts.push(n);
    return `${head}[?]`;
  });
  return counts.length ? `${body.replace(/\n*$/, "\n")}##! summary counts=${counts.join(",")}\n` : wire;
}

function mutate(r: () => number, w: string): string {
  const lines = w.split("\n");
  const i = 1 + Math.floor(r() * (lines.length - 1));
  switch (Math.floor(r() * 6)) {
    case 0: lines.splice(i, 1); break;                              // a missing row or attachment
    case 1: lines.splice(i, 0, lines[i] ?? ""); break;              // a duplicated line
    case 2: lines[i] = (lines[i] ?? "") + "|x"; break;              // row width
    case 3: lines[i] = "  " + (lines[i] ?? ""); break;              // indentation
    case 4: lines[i] = (lines[i] ?? "").replace(/"/, ""); break;     // broken quoting
    default: return w.slice(0, Math.floor(r() * w.length));        // truncation
  }
  return lines.join("\n");
}

const describeOracle = describe.skipIf(!haveOracle);

describeOracle("streaming decode vs the Zig reference", () => {
  test("large tables: nested cells, attachments, flattening, escapes, constants", () => {
    const r = rng(0x5717);
    let decoded = 0;
    for (let t = 0; t < 12; t++) {
      const keys = ["id", "kind", ...["name", "meta", "tags", "a b", "x>y", "note", "é"].filter(() => r() < 0.7)];
      const n = [40, 300, 1500][t % 3];
      const doc: Record<string, unknown> = { tool: "t", rows: Array.from({ length: n }, (_, i) => row(r, i, keys)) };
      if (t % 2) doc.after = { more: Array.from({ length: 50 }, (_, i) => ({ k: i, v: genScalar(r) })), s: "end" };
      const wire = wireOf(doc);
      if (same(wire)) decoded++;
      if (same(deferCounts(wire))) decoded++;
    }
    expect(decoded).toBeGreaterThan(18);
  });

  test("keyed maps, value grouping, expanded arrays and the root forms", () => {
    const r = rng(0xbeef);
    const keyed = Object.fromEntries(Array.from({ length: 800 }, (_, i) => [`node-${i}${i % 7 ? "" : ' "q"'}`, { cpu: i % 97, state: genScalar(r), note: i % 5 ? "ok" : gen(r, 2) }]));
    const expanded = Array.from({ length: 400 }, (_, i) => (i % 3 === 0 ? { inner: Array.from({ length: 5 }, (_, j) => ({ j, s: TRICKY[j] })) } : i % 3 === 1 ? [1, "two", null] : TRICKY[i % TRICKY.length]));
    const docs: unknown[] = [
      { machines: keyed },
      { list: expanded, tail: 1 },
      Array.from({ length: 900 }, (_, i) => ({ i, name: `n${i}`, meta: { a: i % 2 === 0, b: TRICKY[i % TRICKY.length] } })), // anonymous root array
      { a: 1, b: { c: { d: Array.from({ length: 300 }, (_, i) => ({ x: i, y: [i, i + 1] })) } }, e: [] },
      "just a string",
      42,
      {},
      [],
    ];
    const wires = docs.map(wireOf);
    expect(wires[0]).toContain("## machines [800:]{key,"); // a keyed map
    expect(wires[2]).toMatch(/^GCF profile=generic\n## \[900\]/); // an anonymous root array
    for (const wire of wires) {
      expect(same(wire)).toBe(true);
      same(deferCounts(wire));
    }
    const rows = Array.from({ length: 1200 }, (_, i) => ({ id: `u${i}`, team: ["red", "blue", 'x "y"', "7"][i % 4], score: i * 0.5, tag: TRICKY[i % TRICKY.length] }));
    const grouped = call(zig, "gcf_encode_grouped", JSON.stringify({ data: rows, keyField: "id", groupField: "team" }));
    expect(grouped).toContain(" group=team\n");
    expect(same(grouped.slice(4))).toBe(true);
  });

  test("errors in the middle of a streamed document report the same category and line", () => {
    const r = rng(0xe77);
    let errors = 0;
    for (let t = 0; t < 30; t++) {
      const keys = ["id", "kind", "name", "meta", "tags"];
      const wire = wireOf({ rows: Array.from({ length: 200 }, (_, i) => row(r, i, keys)), tail: { x: 1 } });
      for (let m = 0; m < 10; m++) if (!same(mutate(r, t % 2 ? deferCounts(wire) : wire))) errors++;
    }
    expect(errors).toBeGreaterThan(100);
  });
});

// ---------------------------------------------------------------------------
// Memory: streaming keeps peak arena use near the input plus the output
// ---------------------------------------------------------------------------
describe("streaming decode memory", () => {
  const n = 50_000;
  const flat = { users: Array.from({ length: n }, (_, i) => ({ id: i, name: `user${i}`, role: i % 3 ? "dev" : "admin", score: i / 7 })) };
  const mixed = { users: Array.from({ length: n }, (_, i) => ({ id: i, name: `user${i}`, score: i / 7, tags: ["a", "b"], meta: { ok: i % 2 === 0, note: `n "${i}"` } })) };
  // constant columns: the JSON output is ~11x the GCF input
  const constant = { users: Array.from({ length: n }, (_, i) => ({ id: i, kind: "fixed", region: "eu-west", plan: "pro", active: true })) };

  for (const [label, value] of [["flat", flat], ["mixed", mixed], ["constant-column", constant]] as const) {
    test(`${label} table: decode and tape peak near the input plus the output`, async () => {
      const bytes = readFileSync(join(dist, "gcf.wasm"));
      const fresh = async () => (await WebAssembly.instantiate(bytes, {})).instance.exports as unknown as X;
      const e = await fresh();
      const out = call(e, "gcf_encode", JSON.stringify(value), 0);
      const wire = enc.encode(out.slice(4));
      // peak arena use / (input + output)
      const peak = async (fn: string) => {
        const x = await fresh();
        expect(call(x, fn, wire).startsWith("O")).toBe(true);
        return x.gcf_arena_high_water() / (wire.length + x.gcf_output_len());
      };
      // Measured at 50,000 rows: 1.2-1.4 for both (before streaming:
      // decode 3.9-6.9, tape 5.3-6.7).
      expect(await peak("gcf_decode")).toBeLessThan(2);
      expect(await peak("gcf_decode_tape")).toBeLessThan(2);
    });
  }
});
