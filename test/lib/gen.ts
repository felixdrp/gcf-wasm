// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Deterministic generator of JSON values that exercise every GCF layout
// (tabular, flattening, attachments, keyed maps, expanded arrays) and every
// quoting rule. Shared by the encoder and lazy-decoding property tests.

export function rng(seed: number) {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s ^= s >>> 17;
    s ^= s << 5;
    return (s >>> 0) / 4294967296;
  };
}

// Strings chosen to hit every quoting rule (SPEC §2.4) plus ordinary text.
export const TRICKY = [
  "", " ", "-", "~", "^", "^{a,b}", "true", "false", "null", "0", "01", "-0", "1e5", "+1", "-.5", ".5", "1.٥", "123abc",
  "#tag", "@id", ".dot", "a|b", "a,b", 'say "hi"', "back\\slash", "line\nbreak", "tab\there", "cr\rx", "\u0001ctl",
  "\u0085c1", "nb sp", "em sp", "bom﻿", "ERR[404]: Not Found", "[x]y", "a:b", "x>y", "{brace}", "a=b",
  "café", "日本語", "😀 emoji", "trailing ", " leading", "Alice Smith", "plain",
];
export const KEYS = ["id", "name", "value", "a b", "", "x>y", "key", "_key", "type", "tags", "meta", "é", "Ab_9"];

export function genScalar(r: () => number): unknown {
  const k = Math.floor(r() * 7);
  if (k === 0) return null;
  if (k === 1) return r() < 0.5;
  if (k === 2) return Math.floor(r() * 2000) - 1000;
  if (k === 3) return [0.5, -3.25, 1e-7, 6.022e23, 129.5, 0.1, 9007199254740993e10][Math.floor(r() * 7)];
  return TRICKY[Math.floor(r() * TRICKY.length)];
}

function genObject(r: () => number, depth: number, keys = KEYS): Record<string, unknown> {
  const o: Record<string, unknown> = {};
  const n = Math.floor(r() * 5);
  for (let i = 0; i < n; i++) o[keys[Math.floor(r() * keys.length)]] = gen(r, depth + 1);
  return o;
}

export function gen(r: () => number, depth = 0): unknown {
  const k = depth > 4 ? 0 : Math.floor(r() * 10);
  if (k <= 3) return genScalar(r);
  if (k <= 5) return genObject(r, depth);
  if (k === 6) {
    // array of similar objects: tabular / flatten / attachment paths
    const base = Object.keys(genObject(r, depth));
    return Array.from({ length: 1 + Math.floor(r() * 4) }, () => {
      const o: Record<string, unknown> = {};
      for (const key of base) if (r() < 0.85) o[key] = r() < 0.7 ? genScalar(r) : gen(r, depth + 1);
      return o;
    });
  }
  if (k === 7) {
    // keyed map candidate: object of objects
    const o: Record<string, unknown> = {};
    for (let i = 0; i < 2 + Math.floor(r() * 3); i++) o[`m${i}`] = { cpu: Math.floor(r() * 100), state: genScalar(r), note: r() < 0.3 ? gen(r, depth + 1) : "ok" };
    return o;
  }
  return Array.from({ length: Math.floor(r() * 4) }, () => gen(r, depth + 1));
}
