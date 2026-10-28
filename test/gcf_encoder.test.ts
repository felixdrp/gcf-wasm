// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// gcf_encoder.test.ts — properties of the encoder beyond the fixture suite.
//
//   * decode(encode(x)) == x for thousands of generated JSON values
//   * the JavaScript scalar formatter (used by the streaming encoders) and
//     the codec agree on quoting for adversarial strings
//   * large-integer policy, bigint input, streaming, grouping, diff + apply
import { beforeAll, describe, expect, test } from "bun:test";
import { engineWasmPath } from "./lib/engines";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { formatScalar, GcfCodec, GcfError, GenericStreamEncoder, GraphStreamEncoder, needsQuote, type GenericSet } from "../src/host";
import { diff, type Json } from "./lib/json";
import { gen, rng, TRICKY } from "./lib/gen";

let codec: GcfCodec;
beforeAll(async () => {
  codec = await GcfCodec.instantiate(readFileSync(engineWasmPath));
});

describe("encoder properties", () => {
  test("decode(encode(x)) == x for 5,000 generated values (and with noFlatten)", () => {
    const r = rng(0x5eed);
    let checked = 0;
    for (let i = 0; i < 5000; i++) {
      const value = gen(r) as Json;
      for (const noFlatten of [false, true]) {
        const wire = codec.encode(value, { noFlatten });
        let back: Json;
        try {
          back = codec.decode(wire) as Json;
        } catch (e) {
          throw new Error(`round trip #${i} (noFlatten=${noFlatten}): ${e}\nvalue: ${JSON.stringify(value)}\nwire:\n${wire}`);
        }
        // Key order inside tabular rows follows the field union, and flattened
        // objects follow the first row's key order (as in the reference
        // encoders), so values are compared structurally.
        const d = diff(back, value);
        if (d) throw new Error(`round trip #${i} (noFlatten=${noFlatten}): ${d}\nvalue: ${JSON.stringify(value)}\nwire:\n${wire}`);
        checked++;
      }
    }
    expect(checked).toBe(10_000);
  });

  test("JS formatScalar/needsQuote agree with the codec on 3,000 adversarial strings", () => {
    const r = rng(42);
    const pieces = [...TRICKY, "|", ",", '"', "\\", "[", "]", ":", " ", " ", " ", "x", "1", "."];
    for (let i = 0; i < 3000; i++) {
      let s = "";
      const n = Math.floor(r() * 4);
      for (let j = 0; j < n; j++) s += pieces[Math.floor(r() * pieces.length)];
      const line = codec.encode({ v: s }).split("\n")[1];
      expect([s, line]).toEqual([s, `v=${formatScalar(s)}`]);
      expect(line.startsWith('v="')).toBe(needsQuote(s));
    }
  });
});

describe("numbers", () => {
  test("bigint input encodes exact int64 digits; beyond int64 is out_of_range", () => {
    expect(codec.encode({ id: 9223372036854775807n })).toBe("GCF profile=generic\nid=9223372036854775807\n");
    expect(() => codec.encode({ id: 9223372036854775808n })).toThrow(GcfError);
  });

  test("a JS number is a double: integral values >= 2^53 use exponent form", () => {
    expect(codec.encode({ big: 2 ** 60, big2: 1e21, ok: 2 ** 52 })).toBe("GCF profile=generic\nbig=1.152921504606847e+18\nbig2=1e+21\nok=4503599627370496\n");
  });

  test("largeInt policy on decode (SPEC §2.3.2)", () => {
    const wire = "GCF profile=generic\nid=9007199254740993\nsmall=5\n";
    expect(() => codec.decode(wire)).toThrow(/unsafe_integer/);
    expect(codec.decode(wire, { largeInt: "string" })).toEqual({ id: "9007199254740993", small: 5 });
    expect(codec.decode(wire, { largeInt: "bigint" })).toEqual({ id: 9007199254740993n, small: 5 });
    expect(codec.decode(wire, { largeInt: "number" })).toEqual({ id: 9007199254740992, small: 5 });
    expect(codec.decodeToJson(wire)).toBe('{"id":9007199254740993,"small":5}');
  });
});

describe("streaming encoders", () => {
  test("GenericStreamEncoder output decodes to the rows written, with summary counts", () => {
    let out = "";
    const s = new GenericStreamEncoder({ write: (c) => (out += c) });
    s.writeKV("source", "cursor #1");
    s.beginArray("users", ["id", "name", "note"]);
    s.writeRow([1, "Ada", null]);
    s.writeRow([2, "a|b", "true"]);
    s.beginKeyedMap("hosts", "key", ["cpu"]);
    s.writeRow(["web-1", 10]);
    s.close();
    expect(out).toContain("##! summary counts=2,1\n");
    expect(codec.decode(out)).toEqual({
      source: "cursor #1",
      users: [
        { id: 1, name: "Ada", note: null },
        { id: 2, name: "a|b", note: "true" },
      ],
      hosts: { "web-1": { cpu: 10 } },
    });
  });

  test("GraphStreamEncoder output decodes back to the symbols and edges", () => {
    let out = "";
    const g = new GraphStreamEncoder({ write: (c) => (out += c) }, "ctx", { tokenBudget: 100 });
    g.writeSymbol({ qualifiedName: "pkg.A", kind: "function", score: 0.9, provenance: "lsp", distance: 0 });
    g.writeSymbol({ qualifiedName: "pkg.B", kind: "type", score: 0.125, provenance: "ast", distance: 3 });
    g.writeEdge({ source: "pkg.B", target: "pkg.A", edgeType: "calls" });
    g.close();
    const v = codec.decode(out) as { symbols: { qualifiedName: string; score: number; distance: number }[]; edges: unknown[] };
    expect(v.symbols.map((s) => [s.qualifiedName, s.score, s.distance])).toEqual([
      ["pkg.A", 0.9, 0],
      ["pkg.B", 0.12, 3],
    ]);
    expect(v.edges).toEqual([{ source: "pkg.B", target: "pkg.A", edgeType: "calls", status: "" }]);
  });
});

describe("grouping and deltas", () => {
  test("encodeGrouped decodes to the same keyed set", () => {
    const rows = [
      { id: "u1", dept: "Sales", level: 3 },
      { id: "u2", dept: "Eng", level: 1 },
      { id: "u3", dept: "Sales", level: 2 },
    ];
    const wire = codec.encodeGrouped(rows, "id", "dept");
    expect(wire).toContain("group=dept");
    const back = codec.decode(wire) as typeof rows;
    expect([...back].sort((a, b) => a.id.localeCompare(b.id))).toEqual(rows);
  });

  test("diff -> wire -> apply reproduces the next set's pack root", () => {
    const base: GenericSet = { key: "id", fields: ["id", "total", "status"], rows: [1, 2, 3, 4].map((i) => ({ id: i, total: i * 10, status: "open" })) };
    const next: GenericSet = { key: "id", fields: base.fields, rows: [{ id: 1, total: 10, status: "open" }, { id: 2, total: 99, status: "paid" }, { id: 5, total: 50, status: "new" }] };
    const wire = codec.encodeGenericDiff(base, next, { tool: "orders" });
    expect(wire).toContain("## added [1]");
    expect(wire).toContain("## changed [1]");
    expect(wire).toContain("## removed [2]");
    expect(codec.applyGenericDelta(wire, base)).toBe(codec.packRoot(next));
  });

  test("a schema change is rejected by the diff (send a full payload)", () => {
    const base: GenericSet = { key: "id", fields: ["id", "a"], rows: [{ id: 1, a: 1 }] };
    expect(() => codec.encodeGenericDiff(base, { ...base, fields: ["id", "b"] })).toThrow(/schema change/);
  });
});

describe("toJsonText fallback (bigint or 16+ digit integers) matches JSON.stringify", () => {
  test("holes, undefined/function members and toJSON", () => {
    // the bigint forces the custom serialiser; the rest must read as JSON.stringify would
    const holes = [1, , 3]; // eslint-disable-line no-sparse-arrays
    const v = { big: 1n, a: undefined, f: () => 1, arr: holes, list: [undefined, () => 0], d: { toJSON: () => ({ x: 1 }) } };
    const plain = { big: 1, arr: [1, null, 3], list: [null, null], d: { x: 1 } };
    expect(codec.encode(v)).toBe(codec.encode(plain));
  });
});
