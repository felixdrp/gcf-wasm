// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Lossless JSON helpers for the conformance harness.
//
// GCF's numeric domain is exact int64 (SPEC §2.3.2), but `JSON.parse` turns
// every number into a binary64 and silently rounds integers beyond 2^53. The
// harness therefore parses both the fixture files and the engine's JSON
// output with this reader, which keeps unsafe integers as `bigint`.

export type Json = null | boolean | number | bigint | string | Json[] | { [k: string]: Json };

export function parseLossless(text: string): Json {
  let i = 0;
  const ws = () => {
    while (i < text.length) {
      const c = text.charCodeAt(i);
      if (c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09) i++;
      else break;
    }
  };
  const fail = (what: string): never => {
    throw new SyntaxError(`${what} at offset ${i}`);
  };
  const str = (): string => {
    // Find the closing quote, honouring escapes, then defer to JSON.parse for
    // the (standard) string escape grammar.
    const start = i;
    i++;
    while (i < text.length) {
      const c = text[i];
      if (c === "\\") i += 2;
      else if (c === '"') break;
      else i++;
    }
    if (i >= text.length) fail("unterminated string");
    i++;
    return JSON.parse(text.slice(start, i));
  };
  const value = (): Json => {
    ws();
    const c = text[i];
    if (c === "{") {
      i++;
      const obj: { [k: string]: Json } = {};
      ws();
      if (text[i] === "}") {
        i++;
        return obj;
      }
      for (;;) {
        ws();
        if (text[i] !== '"') fail("expected key");
        const k = str();
        ws();
        if (text[i] !== ":") fail("expected ':'");
        i++;
        obj[k] = value();
        ws();
        if (text[i] === ",") {
          i++;
          continue;
        }
        if (text[i] === "}") {
          i++;
          return obj;
        }
        fail("expected ',' or '}'");
      }
    }
    if (c === "[") {
      i++;
      const arr: Json[] = [];
      ws();
      if (text[i] === "]") {
        i++;
        return arr;
      }
      for (;;) {
        arr.push(value());
        ws();
        if (text[i] === ",") {
          i++;
          continue;
        }
        if (text[i] === "]") {
          i++;
          return arr;
        }
        fail("expected ',' or ']'");
      }
    }
    if (c === '"') return str();
    if (text.startsWith("true", i)) {
      i += 4;
      return true;
    }
    if (text.startsWith("false", i)) {
      i += 5;
      return false;
    }
    if (text.startsWith("null", i)) {
      i += 4;
      return null;
    }
    const m = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(text.slice(i, i + 400));
    if (!m) fail("invalid value");
    const lex = m![0];
    i += lex.length;
    if (/^-?\d+$/.test(lex)) {
      const n = Number(lex);
      return Number.isSafeInteger(n) ? n : BigInt(lex);
    }
    return Number(lex);
  };
  const v = value();
  ws();
  if (i !== text.length) fail("trailing data");
  return v;
}

/// Serialise with bigint support (bigints are written as bare digits).
export function stringifyLossless(v: Json): string {
  if (typeof v === "bigint") return v.toString();
  if (Array.isArray(v)) return `[${v.map(stringifyLossless).join(",")}]`;
  if (v !== null && typeof v === "object") {
    return `{${Object.entries(v)
      .map(([k, x]) => `${JSON.stringify(k)}:${stringifyLossless(x)}`)
      .join(",")}}`;
  }
  return JSON.stringify(v);
}

function numEq(a: number | bigint, b: number | bigint): boolean {
  if (typeof a === "bigint" || typeof b === "bigint") {
    try {
      return BigInt(a) === BigInt(b);
    } catch {
      return false; // a non-integral number never equals a bigint
    }
  }
  return a === b; // treats -0 === 0, which is the GCF value model (SPEC §2.3.1)
}

const isNum = (x: unknown): x is number | bigint => typeof x === "number" || typeof x === "bigint";

export type Diff = string | null;

/// Some fixtures cannot pin key order: expectations generated from unordered
/// maps list keys sorted, and '>'-named fields travel as per-row attachments
/// whose position among the columns the spec leaves open (SPEC §7.4.6.1.4).
function orderUnpinned(expectedKeys: string[]): boolean {
  if (expectedKeys.some((k) => k.includes(">"))) return true;
  for (let i = 1; i < expectedKeys.length; i++) if (expectedKeys[i - 1] > expectedKeys[i]) return false;
  return true;
}

/// Structural equality. `orderSensitive` also checks object key order, which
/// the generic profile preserves (SPEC §1.1). `subset` lets `expected` omit
/// object keys (used for graph-profile results, whose fixtures list only the
/// fields they pin).
export function diff(actual: Json, expected: Json, opts: { orderSensitive?: boolean; subset?: boolean } = {}, path = "$"): Diff {
  if (isNum(actual) && isNum(expected)) return numEq(actual, expected) ? null : `${path}: ${actual} !== ${expected}`;
  if (actual === null || expected === null || typeof actual !== "object" || typeof expected !== "object") {
    return actual === expected ? null : `${path}: ${stringifyLossless(actual)} !== ${stringifyLossless(expected)}`;
  }
  if (Array.isArray(actual) !== Array.isArray(expected)) return `${path}: array/object mismatch`;
  if (Array.isArray(actual) && Array.isArray(expected)) {
    if (actual.length !== expected.length) return `${path}: length ${actual.length} !== ${expected.length}`;
    for (let k = 0; k < actual.length; k++) {
      const d = diff(actual[k], expected[k], opts, `${path}[${k}]`);
      if (d) return d;
    }
    return null;
  }
  const a = actual as { [k: string]: Json };
  const e = expected as { [k: string]: Json };
  const ak = Object.keys(a);
  const ek = Object.keys(e);
  if (!opts.subset) {
    if (ak.length !== ek.length || ek.some((k) => !(k in a))) return `${path}: keys [${ak}] !== [${ek}]`;
    if (opts.orderSensitive && ak.join("\u0000") !== ek.join("\u0000") && !orderUnpinned(ek)) {
      return `${path}: key order [${ak}] !== [${ek}]`;
    }
  }
  for (const k of ek) {
    if (!(k in a)) return `${path}.${k}: missing`;
    const d = diff(a[k], e[k], opts, `${path}.${k}`);
    if (d) return d;
  }
  return null;
}

/**
 * Raw JSON text of a top-level member of a JSON object document, byte for
 * byte. Encoder fixtures need it because JS objects reorder integer-like keys
 * ("5", "3"), while the encoder must see the original key order.
 */
export function rawMember(text: string, key: string): string | undefined {
  let i = 0;
  const ws = () => {
    while (i < text.length && " \n\r\t".includes(text[i])) i++;
  };
  const skipString = () => {
    i++;
    while (text[i] !== '"') i += text[i] === "\\" ? 2 : 1;
    i++;
  };
  const skipValue = () => {
    ws();
    if (text[i] === '"') return skipString();
    if (text[i] === "{" || text[i] === "[") {
      let depth = 0;
      while (i < text.length) {
        const c = text[i];
        if (c === '"') {
          skipString();
          continue;
        }
        if (c === "{" || c === "[") depth++;
        else if (c === "}" || c === "]") {
          depth--;
          if (depth === 0) {
            i++;
            return;
          }
        }
        i++;
      }
      return;
    }
    while (i < text.length && !",}] \n\r\t".includes(text[i])) i++;
  };
  ws();
  if (text[i] !== "{") return undefined;
  i++;
  for (;;) {
    ws();
    if (text[i] === "}") return undefined;
    const ks = i;
    skipString();
    const k = JSON.parse(text.slice(ks, i));
    ws();
    i++; // ':'
    ws();
    const vs = i;
    skipValue();
    if (k === key) return text.slice(vs, i);
    ws();
    if (text[i] === ",") i++;
  }
}
