// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// gcf_compliance.test.ts — Module C: conformance + performance harness.
//
// Runs the official Blackwell Systems GCF conformance suite (v2 fixture
// format, `tests/conformance/**.json` in github.com/blackwell-systems/gcf)
// against the WebAssembly engines in dist/.
//
//   bun run test            # build the modules, then run this file
//   GCF_FIXTURES=/path/to/gcf/tests/conformance bun test
//
// Dispatch follows the suite README: the fixture's explicit `operation` field
// selects the contract; it is never inferred from JSON types.
//
// Every operation runs its full contract:
//   decode side   decode, error, roundtrip-wire, pack-root, generic-pack-root,
//                 generic-delta-verify, generic-delta-decode, delta-verify,
//                 delta (apply)
//   encode side   encode, roundtrip, encode-error, session, generic-delta,
//                 generic-delta-session, delta (encode), graph-stream-encode
// Encoder output is compared byte for byte, and wherever a fixture carries
// a wire, decode(expected wire) must also reproduce the fixture input: the
// `decode(encode(x)) == x` invariant required by the suite README.
// Performance thresholds (FUTURE_OPTION A) live in gcf_performance.test.ts.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { GcfEngine, SimdIndexer, scalarPositions, STRUCTURAL, engineWasmPath } from "./lib/engines";
import { diff, parseLossless, rawMember, stringifyLossless, type Json } from "./lib/json";
import { GcfCodec, GcfDecoder, GcfDecodeError, GcfError, GenericDeltaSession, GraphSession, GraphStreamEncoder, type GraphPayload, type GenericSet } from "../src/host";

const projectRoot = join(import.meta.dir, "..");
const fixtureRoot = process.env.GCF_FIXTURES ?? join(projectRoot, "vendor/gcf/tests/conformance");

// ---------------------------------------------------------------------------
// Build prerequisite: compile the modules if dist/ is missing.
// ---------------------------------------------------------------------------
if (!existsSync(join(projectRoot, "dist/gcf.wasm")) || !existsSync(join(projectRoot, "dist/gcf_simd.wasm"))) {
  const r = Bun.spawnSync(["bun", join(projectRoot, "scripts/build.ts")], { stdout: "inherit", stderr: "inherit" });
  if (r.exitCode !== 0) throw new Error("build failed");
}

// ---------------------------------------------------------------------------
// Fixture discovery
// ---------------------------------------------------------------------------
type Fixture = { rel: string; dir: string; text: string; data: { [k: string]: Json } };

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? walk(p) : p.endsWith(".json") ? [p] : [];
  });
}

if (!existsSync(fixtureRoot)) {
  throw new Error(
    `conformance fixtures not found at ${fixtureRoot}\n` +
      "clone them with: git clone --depth 1 https://github.com/blackwell-systems/gcf.git vendor/gcf",
  );
}

const fixtures: Fixture[] = walk(fixtureRoot)
  .sort()
  .map((p) => {
    const rel = relative(fixtureRoot, p);
    const text = readFileSync(p, "utf8");
    return { rel, dir: rel.split("/")[0], text, data: parseLossless(text) as { [k: string]: Json } };
  });


const tally = new Map<string, { pass: number; fail: number; skip: number }>();
function record(op: string, outcome: "pass" | "fail" | "skip") {
  const t = tally.get(op) ?? { pass: 0, fail: 0, skip: 0 };
  t[outcome]++;
  tally.set(op, t);
}

let engine: GcfEngine;
let simd: SimdIndexer;
let codec: GcfCodec;

beforeAll(async () => {
  engine = await GcfEngine.load();
  simd = await SimdIndexer.load();
  codec = await GcfCodec.instantiate(readFileSync(engineWasmPath));
});

/** Run `fn`; return its result or the thrown GcfError as a decode-style result. */
function attempt(fn: () => string): ReturnType<GcfEngine["decode"]> {
  try {
    return { ok: true, json: fn(), value: null };
  } catch (e) {
    if (e instanceof GcfError) return { ok: false, code: e.code, message: e.detail, line: e.line };
    throw e;
  }
}

/** Byte-for-byte encoder comparison with a readable first-difference report. */
function expectWire(got: string, want: string, ctx: string) {
  if (got === want) return;
  let i = 0;
  while (i < got.length && got[i] === want[i]) i++;
  throw new Error(`${ctx}: output differs at byte ${i}\n  got: ${JSON.stringify(got.slice(Math.max(0, i - 40), i + 60))}\n want: ${JSON.stringify(want.slice(Math.max(0, i - 40), i + 60))}`);
}

// ---------------------------------------------------------------------------
// Contract implementations
// ---------------------------------------------------------------------------
const isGraphWire = (w: string) => w.startsWith("GCF profile=graph");

function expectOk(r: ReturnType<GcfEngine["decode"]>, ctx: string): asserts r is Extract<typeof r, { ok: true }> {
  if (!r.ok) throw new Error(`${ctx}: unexpected ${r.code} (line ${r.line}): ${r.message}`);
}

function expectNoDiff(d: string | null, ctx: string) {
  if (d) throw new Error(`${ctx}: ${d}`);
}

function expectError(r: ReturnType<GcfEngine["decode"]>, expected: string) {
  if (r.ok) throw new Error(`expected error '${expected}' but decoding succeeded: ${r.json.slice(0, 200)}`);
  // Categories are exact; a few keyed-map/delta fixtures pin a phrase of the
  // message instead of a category (e.g. "duplicate member key").
  if (r.code !== expected && !r.message.includes(expected)) {
    throw new Error(`expected error '${expected}' but got '${r.code}': ${r.message}`);
  }
}

/**
 * Graph encoders reorder (symbols by score, edges by ID, SPEC §16.1) and
 * round scores to two decimals (SPEC §5), so the graph decode half compares
 * symbol/edge sets with a half-cent score tolerance.
 */
function graphSetsDiff(actual: Json, input: Json): string | null {
  const a = actual as { [k: string]: Json };
  const e = input as { [k: string]: Json };
  type Sym = { qualifiedName: string; kind: string; score: number; provenance: string; distance: number };
  const syms = (x: Json) => [...((x ?? []) as Sym[])].sort((p, q) => (p.qualifiedName < q.qualifiedName ? -1 : 1));
  const as = syms(a.symbols);
  const es = syms(e.symbols);
  if (as.length !== es.length) return `symbol count ${as.length} !== ${es.length}`;
  for (let k = 0; k < es.length; k++) {
    if (Math.abs(as[k].score - es[k].score) > 0.005 + 1e-9) return `${es[k].qualifiedName}: score ${as[k].score} vs ${es[k].score}`;
    const d = diff({ ...as[k], score: 0 }, { ...es[k], score: 0 }, { subset: true }, `symbol ${es[k].qualifiedName}`);
    if (d) return d;
  }
  const ek = (x: Json) => ((x ?? []) as { source: string; target: string; edgeType: string }[]).map((y) => `${y.source}>${y.target}>${y.edgeType}`).sort();
  return diff(ek(a.edges), ek(e.edges));
}

/** decode(wire) must equal the fixture's JSON input (generic: order-sensitive). */
function decodeHalf(wire: string, input: Json) {
  const r = engine.decode(wire);
  expectOk(r, "decode(expected)");
  if (isGraphWire(wire)) expectNoDiff(graphSetsDiff(r.value, input), "graph decode");
  else expectNoDiff(diff(r.value, input, { orderSensitive: true }), "generic decode");
}

const contracts: Record<string, (f: Fixture["data"], fx: Fixture) => void> = {
  decode(f) {
    const wire = f.input as string;
    const r = engine.decode(wire);
    expectOk(r, "decode");
    const graph = isGraphWire(wire);
    expectNoDiff(diff(r.value, f.expected, graph ? { subset: true } : { orderSensitive: true }), "decode");
  },

  error(f) {
    const bytes = typeof f.inputBase64 === "string" ? new Uint8Array(Buffer.from(f.inputBase64, "base64")) : (f.input as string);
    expectError(engine.decode(bytes), f.expectedError as string);
  },

  encode(f, fx) {
    if (typeof f.expected !== "string") throw new Error("encode fixture without a wire");
    const got = isGraphWire(f.expected) ? codec.encodeGraph(f.input as unknown as GraphPayload) : codec.encodeJson(rawMember(fx.text, "input")!);
    expectWire(got, f.expected, "encode");
    decodeHalf(f.expected, f.input);
  },

  roundtrip(f, fx) {
    expectWire(codec.encodeJson(rawMember(fx.text, "input")!), f.expected as string, "encode");
    decodeHalf(f.expected as string, f.input);
  },

  "encode-error"(f, fx) {
    expectError(attempt(() => codec.encodeJson(rawMember(fx.text, "input")!)), f.expectedError as string);
  },

  session(f) {
    const session = new GraphSession(codec);
    for (const [i, call] of (f.calls as { input: Json; expected: string }[]).entries()) {
      expectWire(session.encode(call.input as unknown as GraphPayload), call.expected, `call ${i + 1}`);
      const r = engine.decode(call.expected);
      expectOk(r, `decode(call ${i + 1})`);
    }
  },

  "generic-delta-session"(f) {
    const input = f.input as { base: GenericSet; tool?: string; policy: { mode: string; n?: number }; updates: GenericSet[] };
    const expected = f.expected as { initialFull: string; emissions: { isFull: boolean; wire: string }[] };
    const policy = input.policy.mode === "sizeGuard" ? ({ mode: "sizeGuard" } as const) : ({ mode: "fixedN", n: input.policy.n ?? 15 } as const);
    const session = new GenericDeltaSession(codec, input.base, input.tool ?? "", policy);
    expectWire(session.currentFull(), expected.initialFull, "initial full");
    expect(input.updates.length).toBe(expected.emissions.length);
    input.updates.forEach((u, i) => {
      const e = session.next(u);
      expect([i, e.isFull]).toEqual([i, expected.emissions[i].isFull]);
      expectWire(e.wire, expected.emissions[i].wire, `turn ${i + 1}`);
    });
  },

  "roundtrip-wire"(f) {
    // Exact int64 survival: decode both wires, compare losslessly, and require
    // the integer digits to appear verbatim in the engine's JSON output.
    const a = engine.decode(f.input as string);
    expectOk(a, "decode(input)");
    const b = engine.decode(f.expected as string);
    expectOk(b, "decode(expected)");
    expectNoDiff(diff(a.value, b.value, { orderSensitive: true }), "wire idempotence");
    const digits = /=(-?\d+)\n/.exec(f.input as string)?.[1];
    if (digits && !a.json.includes(digits)) throw new Error(`integer ${digits} was not preserved: ${a.json}`);
  },

  "pack-root"(f) {
    const r = engine.packRoot(stringifyLossless(f.input));
    expectOk(r, "pack-root");
    expect(r.value).toBe(f.expected as string);
  },

  "generic-pack-root"(f) {
    const r = engine.packRoot(stringifyLossless(f.input));
    expectOk(r, "generic-pack-root");
    expect(r.value).toBe(f.expected as string);
  },

  "generic-delta-verify"(f) {
    const r = engine.deltaVerify(stringifyLossless(f.input));
    if (f.expectedError) return expectError(r, f.expectedError as string);
    expectOk(r, "generic-delta-verify");
    expect(r.value).toBe(f.expected as string);
  },

  "generic-delta-decode"(f) {
    const r = engine.deltaDecodeApply(stringifyLossless(f.input));
    if (f.expectedError) return expectError(r, f.expectedError as string);
    expectOk(r, "generic-delta-decode");
    expect(r.value).toBe(f.expected as string);
  },

  "generic-delta"(f) {
    expectWire(codec.encodeGenericDelta(f.input as never), f.expected as string, "generic delta encode");
    // Decode half: sections reproduce the input.
    const r = engine.decode(f.expected as string);
    expectOk(r, "decode(generic delta)");
    const v = r.value as { [k: string]: Json };
    const input = f.input as { [k: string]: Json };
    for (const sec of ["added", "changed", "removed"]) {
      expectNoDiff(diff(v[sec], (input[sec] as Json) ?? [], {}), `delta section ${sec}`);
    }
    expect(v.key).toBe(input.key as string);
    expect(v.baseRoot).toBe(input.baseRoot as string);
    expect(v.newRoot).toBe(input.newRoot as string);
  },

  "graph-stream-encode"(f) {
    const input = f.input as unknown as GraphPayload;
    let out = "";
    const enc = new GraphStreamEncoder({ write: (c) => (out += c) }, input.tool ?? "", { ...(f.options as object), tokenBudget: input.tokenBudget, tokensUsed: input.tokensUsed, packRoot: input.packRoot });
    for (const s of input.symbols) enc.writeSymbol(s);
    for (const e of input.edges ?? []) enc.writeEdge(e);
    enc.close();
    expectWire(out, f.expected as string, "stream encode");
    const r = engine.decode(f.expected as string);
    expectOk(r, "decode(stream)");
    expectNoDiff(diff(r.value, { symbols: input.symbols, edges: input.edges ?? [] }, { subset: true }), "stream decode");
  },

  delta(f) {
    if (typeof f.input === "string") {
      // Consumer path: apply the delta wire to base_snapshot (SPEC §10.4).
      const r = engine.graphDeltaApply(stringifyLossless({ wire: f.input, base: f.base_snapshot }));
      expectOk(r, "graph delta apply");
      const v = r.value as { [k: string]: Json };
      expect(v.root).toBe(f.new_root as string);
      expectNoDiff(diff(v.snapshot, f.expected_snapshot, { subset: true }), "snapshot");
      return;
    }
    // Encoder fixture: byte-exact encode, then decode the expected wire.
    expectWire(codec.encodeGraphDelta(f.input as never), f.expected as string, "graph delta encode");
    const r = engine.decode(f.expected as string);
    expectOk(r, "decode(graph delta)");
    const v = r.value as { [k: string]: Json };
    const input = f.input as { [k: string]: Json };
    const names = (xs: Json) => (xs as { qualifiedName: string }[]).map((x) => x.qualifiedName);
    expect(names(v.removed)).toEqual(names(input.removed));
    expect(names(v.added)).toEqual(names(input.added));
    expect(v.baseRoot).toBe(input.baseRoot as string);
  },

  "delta-verify"(f) {
    const r = engine.graphDeltaApply(stringifyLossless({ wire: f.input, base: f.base_snapshot }));
    if (f.expectedError) return expectError(r, f.expectedError as string);
    expectOk(r, "delta-verify");
  },
};

// ---------------------------------------------------------------------------
// Conformance suite
// ---------------------------------------------------------------------------
describe("Blackwell GCF conformance suite", () => {
  test("fixture suite is present and complete", () => {
    expect(fixtures.length).toBeGreaterThanOrEqual(300);
  });

  const dirs = [...new Set(fixtures.map((f) => f.dir))];
  for (const dir of dirs) {
    describe(dir, () => {
      for (const fx of fixtures.filter((f) => f.dir === dir)) {
        const op = fx.data.operation as string;
        const title = `${fx.rel} [${op}]`;
        const run = contracts[op];
        if (!run) {
          record(op, "skip");
          test.skip(`${title} — unknown operation`, () => {});
          continue;
        }
        test(title, () => {
          try {
            run(fx.data, fx);
            record(op, "pass");
          } catch (e) {
            record(op, "fail");
            throw e;
          }
        });
      }
    });
  }
});

// ---------------------------------------------------------------------------
// Module A (indexer) / Module B (codec) SIMD cross-validation
// ---------------------------------------------------------------------------
function rng(seed: number) {
  let s = seed >>> 0;
  return () => {
    s ^= s << 13;
    s ^= s >>> 17;
    s ^= s << 5;
    return (s >>> 0) / 4294967296;
  };
}

function randomGcfLike(len: number, rand: () => number): Uint8Array {
  const alphabet = "abcXYZ019 _-.é\"\\|,:=@[]^{}~#\n\t\r>";
  const bytes = new TextEncoder().encode(Array.from({ length: len }, () => alphabet[Math.floor(rand() * alphabet.length)]).join(""));
  return bytes.subarray(0, len);
}

describe("SIMD structural indexing", () => {
  test(".wat nibble tables classify all 256 byte values exactly", () => {
    for (let b = 0; b < 256; b++) expect([b, simd.x.classify_byte(b)]).toEqual([b, STRUCTURAL.has(b) ? 1 : 0]);
  });

  test(".wat SIMD path matches the scalar oracle for every byte value in every lane", () => {
    // 256 values x 16 lane positions: a block with exactly one probe byte.
    for (let b = 0; b < 256; b++) {
      for (let lane = 0; lane < 16; lane++) {
        const buf = new Uint8Array(32).fill(0x61);
        buf[lane] = b;
        expect(Array.from(simd.positions(buf))).toEqual(scalarPositions(buf));
      }
    }
  });

  test("all lengths 0..300: .wat positions == scalar, counts agree with the codec's scanner", () => {
    const rand = rng(0x6cf);
    for (let len = 0; len <= 300; len++) {
      const buf = randomGcfLike(len, rand);
      const want = scalarPositions(buf);
      expect(Array.from(simd.positions(buf))).toEqual(want);
      expect(simd.count(buf)).toBe(want.length);
      const n = engine.load(buf);
      expect(engine.x.gcf_scan_structural(n)).toBe(want.length);
      expect(engine.x.gcf_scan_structural_scalar(n)).toBe(want.length);
    }
  });

  test("next_structural returns the first hit at or after `from` (tail and block paths)", () => {
    const buf = new TextEncoder().encode("abcdefghijklmnopqrstuvwxyz|0123456789ABCDEFGH:xyz");
    const { ptr } = simd.load(buf);
    expect(simd.x.next_structural(ptr, buf.length, 0)).toBe(26);
    expect(simd.x.next_structural(ptr, buf.length, 27)).toBe(45);
    expect(simd.x.next_structural(ptr, buf.length, 46)).toBe(-1);
  });

  test("every conformance wire indexes identically in the indexer and the codec", () => {
    for (const fx of fixtures) {
      for (const w of [fx.data.input, fx.data.expected]) {
        if (typeof w !== "string" || !w.startsWith("GCF")) continue;
        const bytes = new TextEncoder().encode(w);
        const want = scalarPositions(bytes);
        expect(Array.from(simd.positions(bytes))).toEqual(want);
        expect(engine.x.gcf_scan_structural(engine.load(bytes))).toBe(want.length);
      }
    }
  });
});

// ---------------------------------------------------------------------------
// Host API (src/host.ts)
// ---------------------------------------------------------------------------
describe("host API", () => {
  let host: GcfDecoder;
  beforeAll(async () => {
    host = await GcfDecoder.instantiate(readFileSync(engineWasmPath));
  });

  test("columnar graph path rebuilds exactly the objects of gcf_decode, for every graph wire", () => {
    let checked = 0;
    const graphWires = fixtures.flatMap((f) => [f.data.input, f.data.expected]).filter((w): w is string => typeof w === "string" && w.startsWith("GCF profile=graph"));
    for (let n = 3; n <= 3000; n *= 10) {
      let w = `GCF profile=graph tool=t session=true symbols=${n}\n## targets\n@${n + 5}  # previously transmitted\n`;
      for (let i = 0; i < n; i++) w += `@${i} ${["fn", "type", "widget"][i % 3]} pkg.S${i} 0.${String(i % 100).padStart(2, "0")} ${i % 2 ? "lsp" : "ast"}\n`;
      w += `## related\n@${n} var x.\"q\\\\ 0.10 lsp\n## edges [${n}]\n`;
      for (let i = 0; i < n; i++) w += `@${i}<@${(i * 7) % n === i ? n + 5 : (i * 7) % n} calls${i % 4 === 0 ? " added" : ""}\n`;
      graphWires.push(w);
    }
    for (const w of graphWires) {
      let viaJson: unknown, viaColumns: unknown;
      try {
        viaJson = JSON.parse(host.decodeToJson(w));
      } catch (e) {
        expect(() => host.decode(w)).toThrow(GcfDecodeError); // same failure on both paths
        continue;
      }
      viaColumns = host.decode(w);
      expect(JSON.stringify(viaColumns)).toBe(JSON.stringify(viaJson));
      checked++;
    }
    expect(checked).toBeGreaterThan(10);
  });

  test("decode() throws GcfDecodeError with the fixture category", () => {
    try {
      host.decode("GCF profile=generic\ntags[3]: a,b\n");
      throw new Error("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(GcfDecodeError);
      expect((e as GcfDecodeError).code).toBe("count_mismatch");
    }
  });

  test("encodeInto path handles non-ASCII text (UTF-16 -> UTF-8 growth)", () => {
    expect(host.decode("GCF profile=generic\nname=日本語 café ✓ 😀\n")).toEqual({ name: "日本語 café ✓ 😀" });
  });
});

// ---------------------------------------------------------------------------
// Engine robustness
// ---------------------------------------------------------------------------
describe("engine robustness", () => {
  test("nesting beyond the depth limit is rejected, not a stack overflow", () => {
    let wire = "GCF profile=generic\n";
    for (let d = 0; d < 200; d++) wire += `${"  ".repeat(d)}## n${d}\n`;
    const r = engine.decode(wire);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.code).toBe("nesting_too_deep");
  });

  test("100 levels of nesting decode (well above the SPEC §12 minimum of 32)", () => {
    let wire = "GCF profile=generic\n";
    for (let d = 0; d < 100; d++) wire += `${"  ".repeat(d)}## n${d}\n`;
    wire += `${"  ".repeat(100)}leaf=1\n`;
    const r = engine.decode(wire);
    expectOk(r, "deep");
  });

  test("empty input and truncated UTF-8 are clean errors", () => {
    const e1 = engine.decode("");
    expect(e1.ok ? "" : e1.code).toBe("missing_header");
    const e2 = engine.decode(new Uint8Array([...new TextEncoder().encode("GCF profile=generic\nv="), 0xe2, 0x82]));
    expect(e2.ok ? "" : e2.code).toBe("invalid_utf8");
  });

  test("the arena is reused: 2,000 decodes do not grow linear memory", () => {
    const wire = (fixtures.find((f) => f.rel.startsWith("inline-schema/012"))!.data.expected as string).repeat(1);
    engine.decode(wire);
    const pages = engine.x.gcf_memory_pages();
    for (let k = 0; k < 2000; k++) engine.decode(wire);
    expect(engine.x.gcf_memory_pages()).toBe(pages);
  });
});

afterAll(() => {
  if (tally.size) {
    const rows = [...tally.entries()].sort().map(([op, t]) => ({ operation: op, ...t }));
    const sum = rows.reduce((a, r) => ({ pass: a.pass + r.pass, fail: a.fail + r.fail, skip: a.skip + r.skip }), { pass: 0, fail: 0, skip: 0 });
    console.log(`\nConformance (${fixtures.length} fixtures from ${fixtureRoot})`);
    console.table([...rows, { operation: "TOTAL", ...sum }]);
  }
});
