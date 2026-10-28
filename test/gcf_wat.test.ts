// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// gcf_wat.test.ts — the codec (dist/gcf.wasm, built from src/wat/*.wat),
// differentially against the Zig reference build (dist/gcf_zig.wasm, from
// the reference/gcf-zig submodule): same ABI, same inputs, byte-identical
// outputs, error categories and lines.
//
// The official fixtures run against the shipped module through the main
// suites (gcf_compliance, gcf_encoder, gcf_boundary). This file adds what the
// fixtures cannot: every export compared with the Zig build on fixture
// inputs, generated inputs and mutated inputs, plus the hand-written number
// conversions and SHA-256 against independent references.
//
// Without dist/gcf_zig.wasm (submodule not checked out, or no Zig) the file
// is skipped with a notice; GCF_REQUIRE_ORACLE=1 makes that a failure.
//
//   bun test test/gcf_wat.test.ts
import { beforeAll, describe, expect, test } from "bun:test";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { parseLossless, stringifyLossless, type Json } from "./lib/json";
import { GcfCodec, GcfError } from "../src/host";
import { gen, genScalar, rng } from "./lib/gen";

const projectRoot = join(import.meta.dir, "..");
const dist = join(projectRoot, "dist");
const fixtureRoot = process.env.GCF_FIXTURES ?? join(projectRoot, "vendor/gcf/tests/conformance");

if (!existsSync(join(dist, "gcf.debug.wasm"))) {
  const r = Bun.spawnSync(["bun", join(projectRoot, "scripts/build.ts")], { stdout: "inherit", stderr: "inherit" });
  if (r.exitCode !== 0) throw new Error("build failed");
}
const haveOracle = existsSync(join(dist, "gcf_zig.wasm"));
if (!haveOracle) {
  if (process.env.GCF_REQUIRE_ORACLE === "1") throw new Error("dist/gcf_zig.wasm missing: git submodule update --init, then bun run build");
  console.warn("gcf_wat.test.ts skipped: no dist/gcf_zig.wasm (git submodule update --init, then bun run build)");
}
/** Every suite here needs the Zig reference build. */
const describeOracle = describe.skipIf(!haveOracle);

type X = { memory: WebAssembly.Memory } & { [k: string]: (...a: number[]) => number };
const enc = new TextEncoder();
const dec = new TextDecoder();
let wat: X;
let zig: X;

beforeAll(async () => {
  if (!haveOracle) return;
  zig = (await WebAssembly.instantiate(readFileSync(join(dist, "gcf_zig.wasm")), {})).instance.exports as unknown as X;
  wat = (await WebAssembly.instantiate(readFileSync(join(dist, "gcf.debug.wasm")), {})).instance.exports as unknown as X;
});

/** Call an export on raw input; the result string captures everything observable. */
function call(x: X, fn: string, input: string | Uint8Array, flags?: number): string {
  const b = typeof input === "string" ? enc.encode(input) : input;
  const p = x.gcf_input_alloc(b.length);
  new Uint8Array(x.memory.buffer, p, b.length).set(b);
  const st = flags === undefined ? x[fn](b.length) : x[fn](b.length, flags);
  const t = (ptr: number, n: number) => dec.decode(new Uint8Array(x.memory.buffer, ptr, n));
  if (st) return `E ${t(x.gcf_error_name_ptr(), x.gcf_error_name_len())} @${x.gcf_error_line()}`;
  const out = new Uint8Array(x.memory.buffer, x.gcf_output_ptr(), x.gcf_output_len());
  return fn === "gcf_decode_tape" ? `O ${Buffer.from(out).toString("hex")}` : `O ${x.gcf_output_unsafe_ints()} ${dec.decode(out)}`;
}

/** Assert the WAT export matches the Zig one; returns the result. */
function same(fn: string, input: string | Uint8Array, flags?: number): string {
  const a = call(zig, fn, input, flags);
  const b = call(wat, fn, input, flags);
  if (a !== b) {
    const show = typeof input === "string" ? input.slice(0, 300) : `<${input.length} bytes>`;
    throw new Error(`${fn} differs on ${JSON.stringify(show)}\n  zig: ${JSON.stringify(a.slice(0, 300))}\n  wat: ${JSON.stringify(b.slice(0, 300))}`);
  }
  return a;
}

// ---------------------------------------------------------------------------
// Fixture inputs
// ---------------------------------------------------------------------------
function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? walk(p) : p.endsWith(".json") ? [p] : [];
  });
}

const fixtures: { [k: string]: Json }[] = existsSync(fixtureRoot) ? walk(fixtureRoot).sort().map((p) => parseLossless(readFileSync(p, "utf8")) as { [k: string]: Json }) : [];
const wires = new Set<string>();
const collect = (v: Json) => {
  if (typeof v === "string" && v.startsWith("GCF")) wires.add(v);
  else if (v && typeof v === "object") for (const k in v as object) collect((v as { [k: string]: Json })[k]);
};
for (const f of fixtures) collect(f);
const isGraph = (w: string) => w.startsWith("GCF profile=graph");
const isDelta = (w: string) => /(^| )delta=true( |$)/.test(w.split("\n", 1)[0]);

/** Structural mutations: insertions of significant characters, deletions, line edits, truncation. */
function mutate(r: () => number, w: string): string {
  const toks = [" ", "  ", "@", "<", "#", "-", "0", "9", ".", "## ", "[", "]", "?", "_", "|", ",", '"', "~", "^", "{", "}", ":", "=", ">", "\n", "\t", "->"];
  const lines = w.split("\n");
  const i = Math.floor(r() * lines.length);
  const p = Math.floor(r() * w.length);
  switch (Math.floor(r() * 8)) {
    case 0: return w.slice(0, p) + toks[Math.floor(r() * toks.length)] + w.slice(p);
    case 1: return w.slice(0, p) + w.slice(p + 1 + Math.floor(r() * 3));
    case 2: lines.splice(i, 1); return lines.join("\n");
    case 3: lines.splice(i, 0, lines[Math.floor(r() * lines.length)]); return lines.join("\n");
    case 4: if (lines[i]) lines[i] = "  " + lines[i]; return lines.join("\n");
    case 5: return w.replace(/\d+/, (d) => String(+d + Math.floor(r() * 3) - 1));
    case 6: return w.replace(/@(\d+)/, (_, d) => "@" + (+d + 1));
    default: return w.slice(0, p);
  }
}

describeOracle("WAT codec vs Zig engine: decoding", () => {
  test("every fixture wire: decode, columnar graph output and lazy tape", () => {
    expect(wires.size).toBeGreaterThan(300);
    for (const w of wires) {
      same("gcf_decode", w);
      same("gcf_decode_tape", w);
      if (isGraph(w)) same("gcf_decode_graph_columns", w);
    }
  });

  test("generated generic values: encode, decode and mutated wires", () => {
    const r = rng(20261012);
    for (let i = 0; i < 1500; i++) {
      const json = JSON.stringify(gen(r));
      same("gcf_encode", json, 0);
      same("gcf_encode", json, 1);
      const out = call(zig, "gcf_encode", json, 0);
      const wire = out.slice(4); // "O 0 " prefix
      same("gcf_decode", wire);
      for (let m = 0; m < 6; m++) same("gcf_decode", mutate(r, m < 3 ? wire : mutate(r, wire)));
    }
  });

  test("graph, graph delta and generic delta wires under mutation", () => {
    const pool = [...wires].filter((w) => isGraph(w) || isDelta(w));
    expect(pool.length).toBeGreaterThan(30);
    const r = rng(7);
    for (let i = 0; i < 8000; i++) {
      let w = pool[Math.floor(r() * pool.length)];
      const k = Math.floor(r() * 4);
      for (let j = 0; j < k; j++) w = mutate(r, w);
      same("gcf_decode", w);
      if (isGraph(w)) same("gcf_decode_graph_columns", w);
    }
  });

  test("malformed bytes: UTF-8, surrogates and control characters", () => {
    const cases = [
      new Uint8Array([...enc.encode('GCF profile=generic\nk="a'), 0xff, ...enc.encode('"\n')]),
      new Uint8Array([...enc.encode("GCF profile=generic\nk="), 0xed, 0xa0, 0x80, 0x0a]),
      new Uint8Array([...enc.encode("GCF profile=generic\nk="), 0xc0, 0x80, 0x0a]),
      enc.encode('GCF profile=generic\nk="a\u0001b"\n'),
      enc.encode('GCF profile=generic\nk="\\ud83d\\ude00 \\u00e9"\n'),
      enc.encode('GCF profile=generic\nk="\\udc00"\n'),
    ];
    for (const b of cases) same("gcf_decode", b);
  });
});

// ---------------------------------------------------------------------------
// Encoders
// ---------------------------------------------------------------------------
describeOracle("WAT codec vs Zig engine: encoders", () => {
  test("encoder input errors (invalid JSON, duplicate keys, depth, ranges)", () => {
    const inputs = ['{"a":1,"a":2}', "[1,2,", '{"x":01}', '"\\ud800"', "[".repeat(200) + "]".repeat(200), '{"big":123456789012345678901}', "1e400", " 7 ", "tru", "[1 2]", '{"a" 1}', "", "-", '"unterminated', '{"k":"\\x"}'];
    for (const s of inputs) same("gcf_encode", s, 0);
  });

  test("graph, session, delta, generic full/delta/diff and grouping on generated inputs", () => {
    const r = rng(11);
    const pick = <T,>(a: T[]) => a[Math.floor(r() * a.length)];
    const many = <T,>(f: () => T, k = 8) => Array.from({ length: Math.floor(r() * k) }, f);
    const kinds = ["function", "type", "method", "interface", "class", "route_handler", "external", "package", "weird", "fn", ""];
    const names = Array.from({ length: 12 }, (_, i) => `pkg.N${i}`);
    const score = () => pick([0.125, 0.625, 0.78, 1, 0.005, -0.5, 0.9, 2, 3.999, 0.115, 1e-300, 7.5, 0, r(), Math.round(r() * 1000) / 100]);
    const sym = () => ({ qualifiedName: pick(names), kind: pick(kinds), score: score(), provenance: pick(["lsp", "ast", "x y", ""]), distance: pick([0, 0, 1, 2, 3, 7, 1.5, -1]) });
    const edge = () => ({ source: pick(names.concat(["nope"])), target: pick(names), edgeType: pick(["calls", "uses", "a b"]), ...(r() < 0.5 ? { status: pick(["", "unchanged", "new"]) } : {}) });
    const graph = () => ({ ...(r() < 0.8 ? { tool: pick(["t", "codetool", ""]) } : {}), ...(r() < 0.6 ? { tokenBudget: pick([0, 5000, 12.7, -3]) } : {}), ...(r() < 0.6 ? { tokensUsed: pick([0, 1847]) } : {}), ...(r() < 0.5 ? { packRoot: "sha256:abc" } : {}), symbols: many(sym, 10), edges: many(edge, 10) });
    const fields = ["id", "name", "qty", "a b"];
    const row = () => Object.fromEntries(fields.filter(() => r() < 0.9).map((f) => [f, f === "id" ? pick([1, 2, 3, 4, 5, "x", "1", null]) : genScalar(r)]));
    const set = () => ({ key: pick(["id", "id", "name", ""]), fields: r() < 0.9 ? fields : [...fields].reverse(), rows: many(row, 6) });
    const gens: [string, () => unknown][] = [
      ["gcf_encode_graph", graph],
      ["gcf_encode_graph_session", () => ({ payload: graph(), known: Object.fromEntries(many(() => [pick(names), pick([0, 3, 9, 2.5])], 5)), next: pick([0, 4, 10, -2, 3.7]) })],
      ["gcf_encode_graph_delta", () => ({ tool: pick(["t", ""]), baseRoot: "sha256:a", newRoot: "sha256:b", deltaTokens: pick([10, 0, 33.3]), fullTokens: pick([100, 0, 7]), removed: many(() => ({ kind: pick(kinds), qualifiedName: pick(names) }), 4), added: many(sym, 4), removedEdges: many(edge, 3), addedEdges: many(edge, 3) })],
      ["gcf_encode_generic_full", () => ({ set: { ...set(), name: pick(["", "items", "a b"]) }, tool: pick(["t", ""]) })],
      ["gcf_encode_generic_delta", () => ({ key: "id", fields, baseRoot: "sha256:a", newRoot: "sha256:b", added: many(row, 3), changed: many(row, 3), removed: many(() => pick([1, "x", null, 2.5]), 3), ...(r() < 0.5 ? { deltaTokens: 5, fullTokens: pick([0, 50]) } : {}), tool: pick(["t", ""]) })],
      ["gcf_generic_diff", () => { const b = set(); return { base: b, next: r() < 0.85 ? { ...b, rows: many(row, 6) } : set(), ...(r() < 0.5 ? { tool: "t", deltaTokens: 3, fullTokens: 9 } : {}) }; }],
      ["gcf_encode_grouped", () => ({ data: many(() => ({ id: pick([1, 2, 3, 4, 5, 6, 7, 8, "k"]), g: pick(["a", "b", 1, null, true]), v: genScalar(r), c: "const" }), 8), keyField: pick(["id", "id", "g", "zz"]), groupField: pick(["g", "g", "v", "id"]) })],
    ];
    for (let i = 0; i < 600; i++) {
      for (const [fn, g] of gens) {
        const s = JSON.stringify(g());
        same(fn, s);
        if (r() < 0.2) {
          const p = Math.floor(r() * s.length);
          same(fn, s.slice(0, p) + pick(['"', "1", "-", "[", "}", "0.5", "null"]) + s.slice(p + 1));
        }
      }
    }
  });

  test("encoder fixture inputs (graph payloads, graph and generic deltas)", () => {
    for (const d of fixtures) {
      if (d.operation === "encode" && typeof d.expected === "string" && isGraph(d.expected)) same("gcf_encode_graph", stringifyLossless(d.input));
      if (d.operation === "delta" && d.input && typeof d.input === "object") same("gcf_encode_graph_delta", stringifyLossless(d.input));
      if (d.operation === "generic-delta") same("gcf_encode_generic_delta", stringifyLossless(d.input));
    }
  });
});

describeOracle("WAT codec: columnar graph input from JS values (gcf_encode_graph_cols)", () => {
  test("encodeGraph through columns gives the bytes of the Zig JSON path, including odd values", async () => {
    const watCodec = await GcfCodec.instantiate(readFileSync(join(dist, "gcf.wasm")));
    const zigCodec = await GcfCodec.instantiate(readFileSync(join(dist, "gcf_zig.wasm")));
    let fast = 0;
    const columns = (watCodec as unknown as { encodeGraphColumns(p: unknown): string | null }).encodeGraphColumns.bind(watCodec);
    (watCodec as unknown as { encodeGraphColumns(p: unknown): string | null }).encodeGraphColumns = (p) => {
      const out = columns(p);
      if (out !== null) fast++;
      return out;
    };
    const run = (c: GcfCodec, p: unknown) => {
      try {
        return "O " + c.encodeGraph(p as never);
      } catch (e) {
        if (e instanceof GcfError) return `E ${e.code}`;
        throw e;
      }
    };
    const r = rng(77);
    const pick = <T,>(a: T[]) => a[Math.floor(r() * a.length)];
    class K { qualifiedName = "pkg.K"; }
    const strs = ["pkg.A", "pkg.B", "pkg.C", "café.ü", "日本", "😀x", "a b", "", "x\ny", "pkg.D"];
    const odd = (): unknown => pick<unknown>([1, 0.5, -0, NaN, Infinity, -1.5, 2 ** 60, 1e30, null, undefined, true, [], {}, 3n, "\ud800lone"]);
    const val = (): unknown => (r() < 0.85 ? pick<unknown>([pick(strs), 1, 0.5, 2]) : odd());
    const sym = () => (r() < 0.02 ? pick<unknown>([null, 5, [], new K(), new Map(), { toJSON: () => ({}) }]) : { qualifiedName: r() < 0.9 ? pick(strs) : val(), kind: pick<unknown>(["function", "type", "fn", "x", "", val()]), score: pick<unknown>([0.125, 0.78, 1, -0, 0.005, r(), val(), 3.999]), provenance: pick<unknown>(["lsp", "ast", val()]), distance: pick<unknown>([0, 0, 1, 2, 3, 1.5, -1, val()]) });
    const edge = () => (r() < 0.02 ? pick<unknown>([null, 7, undefined]) : { source: pick(strs), target: pick(strs), edgeType: pick<unknown>(["calls", "uses", val()]), ...(r() < 0.5 ? { status: pick<unknown>(["", "unchanged", "new", val()]) } : {}) });
    for (let i = 0; i < 2000; i++) {
      const p: Record<string, unknown> = { symbols: Array.from({ length: Math.floor(r() * 12) }, sym), edges: Array.from({ length: Math.floor(r() * 15) }, edge) };
      if (r() < 0.7) p.tool = pick<unknown>(["t", "", val()]);
      if (r() < 0.5) p.tokenBudget = pick<unknown>([0, 5000, 12.7, val()]);
      if (r() < 0.5) p.tokensUsed = pick<unknown>([0, 1847, val()]);
      if (r() < 0.4) p.packRoot = pick<unknown>(["sha256:abc", val()]);
      if (r() < 0.03) (p.symbols as unknown[]).length += 2; // holes
      expect(run(watCodec, p)).toBe(run(zigCodec, p));
    }
    const largeFile = join(projectRoot, "bench/payloads/graph-large.json"); // generated by bench/payloads.ts, if present
    if (existsSync(largeFile)) {
      const large = JSON.parse(readFileSync(largeFile, "utf8"));
      expect(run(watCodec, large)).toBe(run(zigCodec, large));
    }
    expect(fast).toBeGreaterThan(800); // the fast path really ran
  });
});

describeOracle("WAT codec: JS-host numbers in gcf_encode (flags bit 1)", () => {
  test("encode(value) without the integer scan equals the Zig path with it", async () => {
    const watCodec = await GcfCodec.instantiate(readFileSync(join(dist, "gcf.wasm")));
    const zigCodec = await GcfCodec.instantiate(readFileSync(join(dist, "gcf_zig.wasm")));
    const run = (c: GcfCodec, v: unknown, noFlatten: boolean) => {
      try {
        return "O " + c.encode(v, { noFlatten });
      } catch (e) {
        if (e instanceof GcfError) return `E ${e.code}`;
        throw e;
      }
    };
    const r = rng(5);
    const big = [2 ** 53, -(2 ** 53), 2 ** 53 - 1, 2 ** 60, 1e20, -1e20, 1e21, 123456789012345680, 9007199254740993, 1.5e300, 1e16, 1234567890123456, -9999999999999998, 0.1, -0];
    const inject = (v: unknown): unknown => {
      if (Array.isArray(v)) return v.map(inject);
      if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, r() < 0.2 ? big[Math.floor(r() * big.length)] : inject(x)]));
      return r() < 0.1 ? big[Math.floor(r() * big.length)] : v;
    };
    for (let i = 0; i < 3000; i++) {
      const v = i % 3 === 0 ? gen(r) : inject(gen(r));
      for (const nf of [false, true]) expect(run(watCodec, v, nf)).toBe(run(zigCodec, v, nf));
    }
  });

  test("constant columns: numbers that render alike (5, 5.0, 5e0; -0.0, 0) and strings", () => {
    const vals = ["5", "5.0", "5e0", "-0.0", "0", "0.0", "1e2", "100", "9007199254740992", "9007199254740992.0", "9007199254740993", "1.5", "1.50", '"5"', '"a}"', '"a"', "true", "false", "null", "1e300", "-5", "-5.0", "123456789012345678", "1.2345678901234567e17"];
    for (const a of vals) for (const b of vals) same("gcf_encode", `{"rows":[{"k":1,"x":${a}},{"k":2,"x":${b}},{"k":3,"x":${a}}]}`, 0);
  });
});

// ---------------------------------------------------------------------------
// Pack roots and delta application
// ---------------------------------------------------------------------------
describeOracle("WAT codec vs Zig engine: pack roots and deltas", () => {
  test("SHA-256 matches node:crypto on every length 0..300 and larger inputs", () => {
    const r = rng(9);
    for (let n = 0; n < 400; n++) {
      const len = n < 300 ? n : Math.floor(r() * 20000);
      const b = new Uint8Array(len);
      for (let i = 0; i < len; i++) b[i] = Math.floor(r() * 256);
      expect(call(wat, "gcf_debug_sha256", b)).toBe(`O 0 sha256:${createHash("sha256").update(b).digest("hex")}`);
    }
  });

  test("pack roots, delta verify, decode + apply and graph delta apply (fixtures and mutations)", () => {
    const cases: [string, string][] = [];
    for (const d of fixtures) {
      const op = d.operation;
      if (op === "pack-root" || op === "generic-pack-root") cases.push(["gcf_pack_root", stringifyLossless(d.input)]);
      if (op === "generic-delta-verify" || op === "delta-verify") cases.push(["gcf_delta_verify", stringifyLossless(d.input)]);
      if (op === "generic-delta-decode") cases.push(["gcf_delta_decode_apply", stringifyLossless(d.input)]);
      if (op === "delta" && d.base_snapshot) cases.push(["gcf_graph_delta_apply", stringifyLossless({ wire: d.input, base: d.base_snapshot })]);
    }
    expect(cases.length).toBeGreaterThan(10);
    const r = rng(5);
    for (const [fn, s] of cases) same(fn, s);
    for (let i = 0; i < 3000; i++) {
      const [fn, s] = cases[Math.floor(r() * cases.length)];
      const p = Math.floor(r() * s.length);
      same(fn, s.slice(0, p) + '0123456789abcdef"-x'[Math.floor(r() * 19)] + s.slice(p + 1));
    }
  });
});

// ---------------------------------------------------------------------------
// Numbers: the hand-written conversions against the JavaScript engine
// ---------------------------------------------------------------------------
describeOracle("WAT numbers", () => {
  const parse = (s: string) => {
    const b = enc.encode(s);
    const p = wat.gcf_input_alloc(b.length);
    new Uint8Array(wat.memory.buffer, p, b.length).set(b);
    return wat.gcf_debug_parse_f64(b.length);
  };
  const format = (v: number) => {
    wat.gcf_input_alloc(0);
    wat.gcf_debug_format_f64(v);
    return dec.decode(new Uint8Array(wat.memory.buffer, wat.gcf_output_ptr(), wat.gcf_output_len()));
  };
  /** SPEC §2.3.1 canonical form, from the JS shortest round-trip digits. */
  const canonical = (v: number) => {
    if (v === 0) return "0";
    const a = Math.abs(v);
    if (a < 2 ** 53 && (Number.isInteger(a) || a >= 1e-6)) return String(v);
    const [m, e] = v.toExponential().split("e");
    return m + "e" + (e.startsWith("-") ? e : "+" + e.replace("+", ""));
  };
  const dv = new DataView(new ArrayBuffer(8));
  const r = rng(53);
  const randomDouble = () => {
    const k = r();
    if (k < 0.4) {
      dv.setUint32(0, (r() * 2 ** 32) >>> 0);
      dv.setUint32(4, (r() * 2 ** 32) >>> 0);
      const v = dv.getFloat64(0);
      return Number.isFinite(v) ? v : 1.5;
    }
    if (k < 0.7) return (r() - 0.5) * 10 ** Math.floor(r() * 40 - 20);
    if (k < 0.85) return Math.round(r() * 1e6) / 10 ** Math.floor(r() * 8);
    return Number((r() * 1000).toFixed(Math.floor(r() * 6)));
  };

  test("double -> canonical text (Ryu + short-decimal path) matches JS on 100k values", () => {
    const edge = [5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, 0.1, 0.3, 1e21, 1e-7, 2 ** 53, 1.25e21, -0, 1e-6, 4.35, 999999999.999999];
    for (const v of edge) expect(format(v)).toBe(canonical(v));
    for (let i = 0; i < 100_000; i++) {
      const v = randomDouble();
      if (format(v) !== canonical(v)) throw new Error(`format(${v}) = ${format(v)}, expected ${canonical(v)}`);
    }
  });

  test("text -> double (Clinger, Eisel-Lemire, exact fallback) is correctly rounded", () => {
    const hard = ["2.2250738585072011e-308", "9007199254740993.0", "1e23", "4.9e-324", "2.4703282292062327e-324", "2.4703282292062328e-324", "1.7976931348623158e308",
      "0.1000000000000000055511151231257827021181583404541015625", "1.00000000000000011102230246251565404236316680908203125",
      "1.00000000000000011102230246251565404236316680908203124", "1.00000000000000011102230246251565404236316680908203126", "123456789012345678901234567890e-10", "1e-400"];
    for (const s of hard) expect(Object.is(parse(s), Number(s))).toBe(true);
    for (let i = 0; i < 30_000; i++) {
      const v = randomDouble();
      for (const s of [v.toPrecision(17), v.toExponential(20), v.toExponential()]) {
        if (!Object.is(parse(s), Number(s))) throw new Error(`parse(${s}) = ${parse(s)}, expected ${Number(s)}`);
      }
    }
    expect(Number.isNaN(parse("1e400"))).toBe(true); // out_of_range: not a finite double
    expect(Number.isNaN(parse("9223372036854775808"))).toBe(true); // out_of_range: not an int64
  });
});

// ---------------------------------------------------------------------------
// ABI
// ---------------------------------------------------------------------------
describeOracle("WAT codec ABI", () => {
  test("imports nothing and exports exactly the Zig ABI (plus gcf_debug_* helpers and documented extensions)", () => {
    const watMod = new WebAssembly.Module(readFileSync(join(dist, "gcf.debug.wasm")));
    const zigMod = new WebAssembly.Module(readFileSync(join(dist, "gcf_zig.wasm")));
    expect(WebAssembly.Module.imports(watMod)).toEqual([]);
    // __stack_pointer is LLVM's shadow-stack global; the WAT module has no shadow stack
    const zigNames = WebAssembly.Module.exports(zigMod).map((e) => e.name).filter((n) => n !== "__stack_pointer").sort();
    // WAT-only extensions (docs/WASM_ABI.md): the host feature-detects them
    const extensions = ["gcf_encode_graph_cols", "gcf_features"];
    const watNames = WebAssembly.Module.exports(watMod).map((e) => e.name).filter((n) => !n.startsWith("gcf_debug_") && !extensions.includes(n)).sort();
    expect(watNames).toEqual(zigNames);
    expect(wat.gcf_abi_version()).toBe(1);
  });

  test("the shipped build (gcf.wasm) is gcf.debug.wasm without the name section", () => {
    // Split a binary into its sections; custom sections have id 0.
    const sections = (b: Uint8Array) => {
      const out: { id: number; name: string; bytes: Uint8Array }[] = [];
      let i = 8;
      const leb = () => { let r = 0, sh = 0, c; do { c = b[i++]; r |= (c & 0x7f) << sh; sh += 7; } while (c & 0x80); return r >>> 0; };
      while (i < b.length) {
        const start = i;
        const id = b[i++];
        const len = leb();
        const body = i;
        let name = "";
        if (id === 0) { const n = leb(); name = dec.decode(b.subarray(i, i + n)); }
        out.push({ id, name, bytes: b.subarray(start, body + len) });
        i = body + len;
      }
      return out;
    };
    const full = sections(readFileSync(join(dist, "gcf.debug.wasm")));
    const min = sections(readFileSync(join(dist, "gcf.wasm")));
    expect(min.some((s) => s.id === 0)).toBe(false);
    expect(full.some((s) => s.id === 0 && s.name === "name")).toBe(true);
    const code = full.filter((s) => s.id !== 0);
    expect(min.length).toBe(code.length);
    min.forEach((s, k) => expect(Buffer.compare(Buffer.from(s.bytes), Buffer.from(code[k].bytes))).toBe(0));
  });

  test("structural scanners agree with the Zig exports", () => {
    for (let c = 0; c < 256; c++) {
      for (const len of [1, 15, 16, 17, 40]) {
        const b = new Uint8Array(len).fill(c);
        for (const fn of ["gcf_scan_structural", "gcf_scan_structural_scalar"]) {
          const run = (x: X) => { const p = x.gcf_input_alloc(b.length); new Uint8Array(x.memory.buffer, p, b.length).set(b); return x[fn](b.length); };
          expect(run(wat)).toBe(run(zig));
        }
      }
    }
  });

  test("the arena is reused across calls (memory does not grow on repeated decodes)", () => {
    const wire = call(zig, "gcf_encode", JSON.stringify({ rows: Array.from({ length: 2000 }, (_, i) => ({ id: i, name: `n${i}`, v: i / 7 })) }), 0).slice(4);
    call(wat, "gcf_decode", wire);
    const pages = wat.gcf_memory_pages();
    for (let i = 0; i < 50; i++) call(wat, "gcf_decode", wire);
    expect(wat.gcf_memory_pages()).toBe(pages);
  });
});
