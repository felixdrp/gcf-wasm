// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Benchmark payload generator.
//
// Builds deterministic JSON datasets and encodes them with the *reference*
// Blackwell TypeScript encoder, so every benchmark input is canonical GCF as
// the upstream SDK produces it. Payloads are written to bench/payloads/ as
// plain .gcf files plus manifest.json, so other implementations (e.g. a
// future Go runner) can benchmark the exact same bytes.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { encode, encodeGeneric } from "./vendor/gcf-typescript/src/index.ts";

export type PayloadSpec = {
  name: string;
  profile: "generic" | "graph";
  description: string;
  /** GCF wire (canonical output of the reference encoder). */
  file: string;
  bytes: number;
  /** JSON source the wire was encoded from (input for encode benchmarks). */
  jsonFile: string;
  jsonBytes: number;
  /** In-memory source value (not written to the manifest). */
  data?: unknown;
};

function rng(seed: number) {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s ^= s >>> 17;
    s ^= s << 5;
    return (s >>> 0) / 4294967296;
  };
}

const depts = ["Engineering", "Sales", "Marketing", "Support", "Finance", "Legal"];
const tiers = ["basic", "gold", "platinum"];

function tabular(n: number, r = rng(1)) {
  return {
    employees: Array.from({ length: n }, (_, i) => ({
      id: i + 1,
      name: `Employee ${i}`,
      email: `user${i}@example.com`,
      company: "Acme Corp", // constant column (SPEC §7.4.7)
      department: depts[i % depts.length],
      salary: 40000 + Math.floor(r() * 120000),
      active: r() > 0.3,
      score: Math.round(r() * 1000) / 10,
    })),
  };
}

function nestedOrders(n: number, r = rng(2)) {
  return {
    orders: Array.from({ length: n }, (_, i) => ({
      id: `ORD-${100000 + i}`,
      customer: { name: `Customer ${i % 997}`, tier: tiers[i % 3], email: `c${i % 997}@shop.test` }, // flattened
      items: Array.from({ length: 1 + (i % 4) }, (_, k) => ({ sku: `SKU-${(i * 7 + k) % 5000}`, qty: 1 + ((i + k) % 5), price: Math.round(r() * 20000) / 100 })),
      tags: i % 5 === 0 ? [] : ["express", "gift", "fragile"].slice(0, 1 + (i % 3)),
      status: i % 7 === 0 ? null : i % 2 ? "shipped" : "pending",
    })),
  };
}

function keyedMap(n: number, r = rng(3)) {
  const servers: Record<string, unknown> = {};
  for (let i = 0; i < n; i++) {
    servers[`srv-${i.toString(36)}`] = {
      cpu: Math.floor(r() * 100),
      mem: Math.floor(r() * 100),
      region: ["us-east", "eu-west", "ap-south"][i % 3],
      status: r() > 0.9 ? "warn" : "ok",
      uptime: Math.floor(r() * 1e7),
    };
  }
  return { servers };
}

function mixedDeep(n: number, r = rng(4)) {
  const services: unknown[] = [];
  for (let i = 0; i < n; i++) {
    switch (i % 4) {
      case 0:
        services.push(`plain-${i}`);
        break;
      case 1:
        services.push(i * 3.25);
        break;
      case 2:
        services.push({ name: `svc-${i}`, config: { retries: i % 5, timeout: { connect: 100 + (i % 50), read: 2000 }, flags: ["a", "b"] }, owners: [{ team: "core", oncall: i % 2 === 0 }] });
        break;
      default:
        services.push([i, `x${i}`, true, null]);
    }
  }
  return { version: "3.6.0", settings: { region: "eu", limits: { cpu: 4, mem: 8192, nested: { deeper: { deepest: { value: r() } } } } }, services };
}

function quotedStrings(n: number, r = rng(5)) {
  const samples = ["has, comma", "pipe | inside", 'quote " inside', "back\\slash", "tab\there", "newline\nhere", "  padded  ", "true", "123", "-", "café ünïcödé ✓", "日本語テキスト", "", "#hash", "@at", "[x]: y"];
  return Array.from({ length: n }, (_, i) => ({ id: i, a: samples[i % samples.length], b: samples[(i * 7) % samples.length], note: `row ${i} ${r() > 0.5 ? "ok" : "check"}` }));
}

function graph(n: number, r = rng(6)) {
  const kinds = ["function", "type", "method", "interface", "var", "const"];
  const symbols = Array.from({ length: n }, (_, i) => ({
    qualifiedName: `github.com/org/repo/pkg${i % 64}.Symbol${i}`,
    kind: kinds[i % kinds.length],
    score: Math.round(r() * 100) / 100,
    provenance: i % 3 ? "lsp_resolved" : "ast_inferred",
    distance: i < n / 10 ? 0 : i < n / 3 ? 1 : i < (2 * n) / 3 ? 2 : 3 + (i % 3),
  }));
  const edges = Array.from({ length: Math.floor(n * 1.5) }, (_, k) => ({
    source: symbols[(k * 7 + 3) % n].qualifiedName,
    target: symbols[(k * 13 + 1) % n].qualifiedName,
    edgeType: ["calls", "imports", "references", "implements"][k % 4],
  }));
  return { tool: "context_for_task", tokenBudget: 50000, tokensUsed: 0, symbols, edges };
}

/** Generate every payload (small and large variants) and write them to disk. */
export function generatePayloads(outDir: string): PayloadSpec[] {
  mkdirSync(outDir, { recursive: true });
  const specs: PayloadSpec[] = [];
  const add = (name: string, profile: "generic" | "graph", description: string, data: unknown) => {
    const wire = profile === "graph" ? encode(data as never) : encodeGeneric(data);
    const json = JSON.stringify(data);
    const file = `${name}.gcf`;
    const jsonFile = `${name}.json`;
    writeFileSync(join(outDir, file), wire);
    writeFileSync(join(outDir, jsonFile), json);
    specs.push({ name, profile, description, file, bytes: Buffer.byteLength(wire), jsonFile, jsonBytes: Buffer.byteLength(json), data });
  };
  for (const [suffix, scale] of [["small", 1], ["large", 400]] as const) {
    add(`tabular-${suffix}`, "generic", "flat tabular array + constant column", tabular(50 * scale));
    add(`nested-${suffix}`, "generic", "flattened objects, array attachments", nestedOrders(15 * scale));
    add(`keyed-${suffix}`, "generic", "keyed map [N:] of objects", keyedMap(40 * scale));
    add(`mixed-${suffix}`, "generic", "sections, expanded mixed arrays, deep nesting", mixedDeep(12 * scale));
    add(`quoted-${suffix}`, "generic", "quoting/escapes/Unicode-heavy strings", quotedStrings(40 * scale));
    add(`graph-${suffix}`, "graph", "graph profile: symbols, groups, edges", graph(25 * scale));
  }
  const manifest = specs.map(({ data: _data, ...rest }) => rest);
  writeFileSync(join(outDir, "manifest.json"), JSON.stringify({ generator: "bench/payloads.ts", encoder: "@blackwell-systems/gcf (gcf-typescript source)", payloads: manifest }, null, 2) + "\n");
  return specs;
}
