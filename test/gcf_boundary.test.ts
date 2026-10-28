// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// gcf_boundary.test.ts — the two boundary-cost techniques of
// docs/JS_WASM_BOUNDARY.md: the bytes-in/bytes-out API and lazy decoding.
import { beforeAll, describe, expect, test } from "bun:test";
import { engineWasmPath } from "./lib/engines";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { GcfCodec, GcfError, toPlain } from "../src/host";
import { gen, rng } from "./lib/gen";

const root = join(import.meta.dir, "..");
let gcf: GcfCodec;
beforeAll(async () => {
  gcf = await GcfCodec.instantiate(readFileSync(engineWasmPath));
});

/** Every valid GCF wire in the official suite (decode inputs, encode outputs). */
function fixtureWires(): string[] {
  const dir = join(root, "vendor/gcf/tests/conformance");
  const walk = (d: string): string[] =>
    readdirSync(d).flatMap((f) => {
      const p = join(d, f);
      return statSync(p).isDirectory() ? walk(p) : p.endsWith(".json") ? [p] : [];
    });
  const out: string[] = [];
  for (const f of walk(dir)) {
    const j = JSON.parse(readFileSync(f, "utf8"));
    if (j.expectedError) continue; // fixtures whose wire must fail
    for (const w of [j.input, j.expected, j.input?.wire]) if (typeof w === "string" && w.startsWith("GCF")) out.push(w);
    for (const c of j.calls ?? []) out.push(c.expected);
  }
  return out;
}

const enc = new TextEncoder();
const dec = new TextDecoder();

describe("bytes in, bytes out", () => {
  test("encodeJsonBytes / decodeToJsonBytes match the string API", () => {
    const value = { users: [{ id: 1, name: "Ada", note: "a|b" }, { id: 2, name: "Ünïcode ✓", note: null }], n: 9007199254740993n };
    const json = '{"users":[{"id":1,"name":"Ada","note":"a|b"},{"id":2,"name":"Ünïcode ✓","note":null}],"n":9007199254740993}';
    const gcfBytes = gcf.encodeJsonBytes(enc.encode(json));
    expect(dec.decode(gcfBytes)).toBe(gcf.encode(value));
    expect(dec.decode(gcf.decodeToJsonBytes(gcfBytes))).toBe(gcf.decodeToJson(dec.decode(gcfBytes)));
    expect(dec.decode(gcf.decodeToJsonBytes(gcfBytes))).toContain("9007199254740993"); // exact digits, no policy
  });

  test("graph profile", () => {
    const payload = { tool: "t", symbols: [{ qualifiedName: "a.B", kind: "function", score: 0.5, provenance: "lsp", distance: 0 }], edges: [] };
    expect(dec.decode(gcf.encodeJsonBytes(JSON.stringify(payload), { profile: "graph" }))).toBe(gcf.encodeGraph(payload));
  });

  test("copies are owned; views are only valid until the next call", () => {
    const owned = gcf.decodeToJsonBytes("GCF profile=generic\nx=1\n");
    const view = gcf.decodeToJsonBytes("GCF profile=generic\nx=2\n", { view: true });
    expect(dec.decode(view)).toBe('{"x":2}');
    gcf.decodeToJson("GCF profile=generic\nzzzzzzz=3\n"); // reuses the arena
    expect(dec.decode(owned)).toBe('{"x":1}');
  });

  test("errors are GcfError", () => {
    expect(() => gcf.decodeToJsonBytes(enc.encode("GCF profile=generic\nx=~\n"))).toThrow(GcfError);
    expect(() => gcf.encodeJsonBytes(enc.encode('{"a":1,"a":2}'))).toThrow(/duplicate_key/);
  });
});

describe("lazy decoding", () => {
  test("decodeLazy equals decode on every conformance wire (proxies and toPlain)", () => {
    const wires = fixtureWires();
    expect(wires.length).toBeGreaterThan(200);
    for (const w of wires) {
      const eager = JSON.stringify(gcf.decode(w, { largeInt: "string" }));
      const lazy = gcf.decodeLazy(w, { largeInt: "string" });
      // Proxies keep the document's key order even for integer-like keys,
      // which plain objects (eager decode, toPlain) move to the front, so
      // the proxy view is compared structurally.
      expect([w, JSON.parse(JSON.stringify(lazy))]).toEqual([w, JSON.parse(eager)]);
      expect([w, JSON.stringify(toPlain(lazy))]).toEqual([w, eager]);
    }
  });

  test("decodeLazy equals decode on 3,000 generated documents", () => {
    const r = rng(0xbad5eed);
    for (let i = 0; i < 3000; i++) {
      const text = gcf.encode(gen(r));
      const eager = gcf.decode(text);
      const lazy = gcf.decodeLazy(text);
      expect(JSON.parse(JSON.stringify(lazy))).toEqual(eager as object);
      expect(JSON.stringify(toPlain(lazy))).toBe(JSON.stringify(eager));
    }
  });

  test("behaves like plain objects and arrays", () => {
    const v = gcf.decodeLazy(gcf.encode({ rows: [{ id: 1, tags: ["x", "y"] }, { id: 2, tags: [] }], meta: { ok: true } })) as {
      rows: { id: number; tags: string[] }[];
      meta: { ok: boolean };
    };
    expect(Array.isArray(v.rows)).toBe(true);
    expect(v.rows.length).toBe(2);
    expect(v.rows.map((r) => r.id)).toEqual([1, 2]);
    expect([...v.rows[0].tags]).toEqual(["x", "y"]);
    expect(Object.keys(v)).toEqual(["rows", "meta"]);
    expect(Object.entries(v.meta)).toEqual([["ok", true]]);
    expect("meta" in v && !("nope" in v)).toBe(true);
    expect((v as Record<string, unknown>).nope).toBeUndefined();
    expect(v.rows === v.rows).toBe(true); // proxies are cached
  });

  test("keeps document key order, including integer-like keys", () => {
    const v = gcf.decodeLazy('GCF profile=generic\nid=1\n"5"=a\nname=x\n');
    expect(Object.keys(v as object)).toEqual(["id", "5", "name"]);
    expect(Object.keys(gcf.decode('GCF profile=generic\nid=1\n"5"=a\nname=x\n') as object)).toEqual(["5", "id", "name"]);
  });

  test("is read-only", () => {
    const v = gcf.decodeLazy("GCF profile=generic\nx=1\n") as { x: number };
    expect(() => {
      "use strict";
      (v as { x: number }).x = 2;
    }).toThrow(TypeError);
    expect(v.x).toBe(1);
  });

  test("stays valid after later codec calls", () => {
    const v = gcf.decodeLazy(gcf.encode({ name: "keep me", list: [1, 2, 3] })) as { name: string; list: number[] };
    for (let i = 0; i < 50; i++) gcf.decode(gcf.encode({ other: i, filler: "x".repeat(i * 100) }));
    expect(v.name).toBe("keep me");
    expect([...v.list]).toEqual([1, 2, 3]);
  });

  test("large integers follow the largeInt policy, on access", () => {
    const text = "GCF profile=generic\nid=9007199254740993\nsmall=-134217728\nmid=4294967296\n";
    const v = gcf.decodeLazy(text) as Record<string, unknown>;
    expect(v.small).toBe(-134217728); // 28-bit inline boundary
    expect(v.mid).toBe(4294967296); // two-word int64, still safe
    expect(() => v.id).toThrow(/unsafe_integer/);
    expect((gcf.decodeLazy(text, { largeInt: "bigint" }) as Record<string, unknown>).id).toBe(9007199254740993n);
    expect((gcf.decodeLazy(text, { largeInt: "string" }) as Record<string, unknown>).id).toBe("9007199254740993");
  });

  test("decode errors are thrown eagerly", () => {
    expect(() => gcf.decodeLazy("GCF profile=generic\n## rows [2]{id}\n1\n")).toThrow(/count_mismatch/);
  });
});
