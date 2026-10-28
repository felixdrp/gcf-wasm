// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Generates src/wat/_tables.gen.wat: the static data of the hand-written WAT
// codec. Only *data* is generated here (lookup tables, error strings); all
// code in src/wat/*.wat is written by hand.
//
// Static memory map (page 0, below the heap at 0x10000):
//   0x0100  digit pairs "00".."99"                     200 B
//   0x0200  exact powers of ten 1e0..1e22 (f64)        184 B
//   0x0300  error names: 64 x (u32 offset, u32 len)    512 B
//   0x0500  messages:   128 x (u32 offset, u32 len)   1024 B
//   0x0900  string pool for names and messages
//   0x2000  Ryu DOUBLE_POW5_INV_SPLIT: 342 x (lo u64, hi u64)
//   0x3600  Ryu DOUBLE_POW5_SPLIT:     326 x (lo u64, hi u64)
//   0x4C00  Eisel-Lemire powers of ten 1e-348..1e347: 696 x (lo u64, hi u64)
//   0x7800  structural nibble tables (lo, hi): 2 x 16 B
//   0x7C00  graph kind table: 16 x (abbr off, abbr len, full off, full len)
//   0x7D00  SHA-256 round constants: 64 x u32
//   0x8000  named string pool: globals $K_<name> (offset) and $K_<name>_n (length)
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// Error categories, in the exact order of gcf.zig `ErrorCode` (ABI numbers).
export const ERROR_NAMES = [
  "none", "missing_header", "missing_profile", "unknown_profile", "malformed_header_field", "duplicate_header_field",
  "unterminated_quote", "invalid_escape", "trailing_characters", "invalid_missing", "invalid_attachment_marker",
  "invalid_surrogate", "invalid_utf8", "invalid_control_character", "out_of_range", "duplicate_key", "duplicate_field_name",
  "row_width_mismatch", "count_mismatch", "invalid_count", "tab_indentation", "invalid_indent", "invalid_item_id",
  "orphan_attachment", "orphan_inline_attachment", "missing_attachment", "duplicate_attachment", "inline_width_mismatch",
  "invalid_key", "invalid_line", "invalid_const_value", "no_bare_column", "invalid_group_header", "duplicate_group",
  "invalid_node_line", "invalid_symbol_id", "invalid_score", "invalid_edge_syntax", "unknown_edge_reference",
  "unknown_section", "malformed_delta", "root_mismatch", "delta_conflict", "invalid_json", "invalid_input",
  "nesting_too_deep", "out_of_memory",
];

// Default message per code (index = code), then specific messages from 64 on.
// Messages that fixtures check by phrase keep that phrase verbatim.
const DEFAULT_MESSAGES: Record<string, string> = {
  missing_header: "payload must begin with a 'GCF profile=...' header line",
  missing_profile: "header has no 'profile=' field",
  unknown_profile: "unknown profile (expected generic or graph)",
  malformed_header_field: "malformed header or field declaration",
  duplicate_header_field: "duplicate header field",
  unterminated_quote: "unterminated quoted string",
  invalid_escape: "invalid escape sequence",
  trailing_characters: "characters after closing quote",
  invalid_missing: "the missing marker '~' is valid only in tabular row cells",
  invalid_attachment_marker: "attachment marker is valid only in tabular row cells",
  invalid_surrogate: "invalid surrogate",
  invalid_utf8: "invalid UTF-8",
  invalid_control_character: "raw control character in quoted string",
  out_of_range: "number outside the int64 / double domain; model it as a string at the producer",
  duplicate_key: "duplicate key",
  duplicate_field_name: "duplicate field name",
  row_width_mismatch: "row cell count does not match the header",
  count_mismatch: "declared count does not match the number of items",
  invalid_count: "invalid count",
  tab_indentation: "tab character in indentation",
  invalid_indent: "invalid indentation",
  invalid_item_id: "item ID does not equal its index",
  orphan_attachment: "attachment does not correspond to a '^' cell",
  orphan_inline_attachment: "positional inline body has no eligible attachment marker",
  missing_attachment: "attachment marker without an attachment body",
  duplicate_attachment: "more than one attachment for the same field",
  inline_width_mismatch: "inline body width does not match its schema",
  invalid_key: "invalid key",
  invalid_line: "unexpected line",
  invalid_const_value: "invalid constant column value",
  no_bare_column: "every field is a constant column; rows would have no cells",
  invalid_group_header: "invalid value-grouping header",
  duplicate_group: "duplicate group value",
  invalid_node_line: "invalid node line",
  invalid_symbol_id: "invalid symbol ID",
  invalid_score: "invalid score",
  invalid_edge_syntax: "invalid edge syntax",
  unknown_edge_reference: "edge references an undeclared symbol",
  unknown_section: "unknown section",
  malformed_delta: "malformed delta payload",
  root_mismatch: "pack root mismatch",
  delta_conflict: "contradictory delta operation",
  invalid_json: "invalid JSON",
  invalid_input: "invalid input for this encoding",
  nesting_too_deep: "nesting deeper than 128 levels",
  out_of_memory: "out of memory",
};
export const SPECIFIC_MESSAGES = [
  /* 64 */ "duplicate member key in keyed map",
  /* 65 */ "keyed map header requires at least two fields (key column plus one value field)",
  /* 66 */ "keyed map has zero count; an empty object is never written as [0:]",
  /* 67 */ "graph and delta payloads are not implemented by the WAT codec yet (phase 2)",
  /* 68 */ "duplicate key in input object",
  /* 69 */ "a row with attachment markers must carry an @N row ID",
  /* 70 */ "unexpected content after the root value",
  /* 71 */ "group counts do not match the section count",
  /* 72 */ "added identity already exists in the base set",
  /* 73 */ "changed identity does not exist in the base set",
  /* 74 */ "removed identity does not exist in the base set",
  /* 75 */ "removed symbol does not exist in the base snapshot",
  /* 76 */ "symbol removed twice",
  /* 77 */ "added symbol already exists in the base snapshot",
  /* 78 */ "removed edge does not exist in the base snapshot",
  /* 79 */ "added edge already exists in the base snapshot",
  /* 80 */ "pack root rows must contain scalar values only",
  /* 81 */ "delta_invalid: no identity key",
  /* 82 */ "delta_invalid: schema change (send full)",
];

// Graph kind abbreviations (SPEC §5), same order as gcf.zig kind_table.
export const KINDS: [string, string][] = [
  ["fn", "function"], ["type", "type"], ["method", "method"], ["iface", "interface"], ["var", "var"], ["const", "const"],
  ["resource", "resource"], ["table", "table"], ["class", "class"], ["selector", "selector"], ["field", "field"],
  ["route", "route_handler"], ["ext", "external"], ["file", "file"], ["pkg", "package"], ["svc", "service"],
];

// Named strings used by the phase-2 code (keys, header fields, section names).
// [global name, text]; the generator lays them out and emits their offsets.
export const KSTRINGS: [string, string][] = [
  ["tool", "tool"], ["tokenBudget", "tokenBudget"], ["tokensUsed", "tokensUsed"], ["packRoot", "packRoot"], ["unchanged", "unchanged"],
  ["session", "session"], ["symbols", "symbols"], ["edges", "edges"], ["references", "references"], ["qualifiedName", "qualifiedName"],
  ["kind", "kind"], ["score", "score"], ["provenance", "provenance"], ["distance", "distance"], ["source", "source"], ["target", "target"],
  ["edgeType", "edgeType"], ["status", "status"], ["delta", "delta"], ["baseRoot", "baseRoot"], ["newRoot", "newRoot"], ["removed", "removed"],
  ["added", "added"], ["edgesRemoved", "edgesRemoved"], ["edgesAdded", "edgesAdded"], ["changed", "changed"], ["key", "key"],
  ["budget", "budget"], ["tokens", "tokens"], ["pack_root", "pack_root"], ["base_root", "base_root"], ["new_root", "new_root"],
  ["targets", "targets"], ["related", "related"], ["extended", "extended"], ["distance_", "distance_"], ["edges_removed", "edges_removed"],
  ["edges_added", "edges_added"], ["prev_tx", "# previously transmitted"], ["edges_eq", "edges="], ["arrow", "->"], ["hash", "#"],
  ["names", "names"], ["kinds", "kinds"], ["provs", "provs"], ["types", "types"], ["statuses", "statuses"],
  ["c_k", "k"], ["c_p", "p"], ["c_es", "es"], ["c_et", "et"], ["c_ty", "ty"], ["c_st", "st"], ["c_s", "s"], ["c_d", "d"],
  ["sha256", "sha256:"], ["rows", "rows"], ["fields", "fields"], ["base", "base"], ["wire", "wire"], ["expectedNewRoot", "expectedNewRoot"],
  ["root", "root"], ["snapshot", "snapshot"], ["data", "data"], ["keyField", "keyField"], ["groupField", "groupField"],
  ["payload", "payload"], ["known", "known"], ["next", "next"], ["set", "set"], ["name", "name"], ["deltaTokens", "deltaTokens"],
  ["fullTokens", "fullTokens"], ["summary", "##! summary"], ["hex", "0123456789abcdef"],
  ["graph_hdr", "GCF profile=graph"], ["removedEdges", "removedEdges"], ["addedEdges", "addedEdges"], ["savings", "savings"],
  ["edges_hdr", "## edges ["], ["sp_arrow", " -> "], ["lt_at", "<@"], ["prev_line", "  # previously transmitted\n"],
];

const pow5bits = (e: number) => Math.floor((e * 1217359) / 2 ** 19) + 1;
const bitlen = (x: bigint) => x.toString(2).length;
const M64 = (1n << 64n) - 1n;

function ryuTables() {
  const inv: bigint[] = [];
  const pos: bigint[] = [];
  for (let i = 0; i < 342; i++) {
    const p = 5n ** BigInt(i);
    const j = BigInt(bitlen(p) - 1 + 125);
    inv.push((1n << j) / p + 1n);
  }
  for (let i = 0; i < 326; i++) {
    const p = 5n ** BigInt(i);
    const j = bitlen(p) - 125;
    pos.push(j >= 0 ? p >> BigInt(j) : p << BigInt(-j));
  }
  return { inv, pos };
}

/** 128-bit mantissas of 10^e, rounded down (Go strconv detailedPowersOfTen). */
function eiselLemireTable() {
  const out: bigint[] = [];
  for (let e = -348; e <= 347; e++) {
    let m: bigint;
    if (e >= 0) {
      const p = 10n ** BigInt(e);
      const b = bitlen(p);
      m = b >= 128 ? p >> BigInt(b - 128) : p << BigInt(128 - b);
    } else {
      const d = 10n ** BigInt(-e);
      // floor(2^k / d) with exactly 128 bits
      let k = bitlen(d) + 127;
      m = (1n << BigInt(k)) / d;
      if (bitlen(m) < 128) m = (1n << BigInt(k + 1)) / d;
    }
    out.push(m);
  }
  return out;
}

const hexBytesLE = (x: bigint, n: number) => {
  let s = "";
  for (let i = 0; i < n; i++) s += "\\" + Number((x >> BigInt(8 * i)) & 0xffn).toString(16).padStart(2, "0");
  return s;
};
const pair = (v: bigint) => hexBytesLE(v & M64, 8) + hexBytesLE(v >> 64n, 8);
const escape = (s: string) => [...new TextEncoder().encode(s)].map((b) => (b >= 0x20 && b < 0x7f && b !== 0x22 && b !== 0x5c ? String.fromCharCode(b) : "\\" + b.toString(16).padStart(2, "0"))).join("");

export function generate(): string {
  const lines: string[] = [";; GENERATED by scripts/gen-wat-tables.ts — do not edit. Data only.", ""];
  // digit pairs
  let dp = "";
  for (let i = 0; i < 100; i++) dp += String(i).padStart(2, "0");
  lines.push(`(data (i32.const 0x0100) "${dp}")`);
  // exact powers of ten (f64, little-endian)
  const buf = new DataView(new ArrayBuffer(8));
  let pw = "";
  for (let i = 0; i <= 22; i++) {
    buf.setFloat64(0, 10 ** i, true);
    for (let b = 0; b < 8; b++) pw += "\\" + buf.getUint8(b).toString(16).padStart(2, "0");
  }
  lines.push(`(data (i32.const 0x0200) "${pw}")`);
  // strings: names and messages
  let pool = "";
  let poolLen = 0;
  const addString = (s: string) => {
    const off = 0x0900 + poolLen;
    const bytes = new TextEncoder().encode(s);
    pool += escape(s);
    poolLen += bytes.length;
    return [off, bytes.length] as const;
  };
  const names = ERROR_NAMES.map(addString);
  const msgs: (readonly [number, number])[] = [];
  for (let i = 0; i < 128; i++) {
    const text = i < ERROR_NAMES.length ? DEFAULT_MESSAGES[ERROR_NAMES[i]] ?? "" : SPECIFIC_MESSAGES[i - 64] ?? "";
    msgs.push(text ? addString(text) : ([0, 0] as const));
  }
  if (0x0900 + poolLen > 0x2000) throw new Error("string pool overflow");
  const u32 = (v: number) => hexBytesLE(BigInt(v), 4);
  lines.push(`(data (i32.const 0x0300) "${names.map(([o, l]) => u32(o) + u32(l)).join("")}")`);
  lines.push(`(data (i32.const 0x0500) "${msgs.map(([o, l]) => u32(o) + u32(l)).join("")}")`);
  lines.push(`(data (i32.const 0x0900) "${pool}")`);
  // Ryu
  const { inv, pos } = ryuTables();
  lines.push(`(data (i32.const 0x2000) "${inv.map(pair).join("")}")`);
  lines.push(`(data (i32.const 0x3600) "${pos.map(pair).join("")}")`);
  // Eisel-Lemire
  lines.push(`(data (i32.const 0x4C00) "${eiselLemireTable().map(pair).join("")}")`);
  // structural nibble tables (same as gcf_simd.wat)
  lines.push(`(data (i32.const 0x7800) "\\08\\00\\02\\02\\00\\00\\00\\00\\00\\00\\05\\30\\22\\34\\30\\00\\01\\00\\02\\04\\08\\10\\00\\20\\00\\00\\00\\00\\00\\00\\00\\00")`);
  // named string pool and kind table
  let kpool = "";
  let klen = 0;
  const kOff = new Map<string, [number, number]>();
  const addK = (text: string) => {
    const bytes = new TextEncoder().encode(text);
    const off = 0x8000 + klen;
    kpool += escape(text);
    klen += bytes.length;
    return [off, bytes.length] as [number, number];
  };
  for (const [name, text] of KSTRINGS) {
    if (kOff.has(name)) throw new Error(`duplicate string name ${name}`);
    kOff.set(name, addK(text));
  }
  let kinds = "";
  for (const [abbr, full] of KINDS) {
    const [ao, al] = addK(abbr);
    const [fo, fl] = addK(full);
    kinds += u32(ao) + u32(al) + u32(fo) + u32(fl);
  }
  if (0x8000 + klen > 0x10000) throw new Error("named string pool overflow");
  lines.push(`(data (i32.const 0x7C00) "${kinds}")`);
  // SHA-256 round constants: first 32 bits of the fractional parts of the
  // cube roots of the first 64 primes (computed exactly with BigInt)
  const primes: number[] = [];
  for (let c = 2; primes.length < 64; c++) if (primes.every((q) => c % q !== 0)) primes.push(c);
  const icbrt = (x: bigint) => { let lo = 0n, hi = 1n << 64n; while (lo < hi) { const m = (lo + hi + 1n) >> 1n; if (m * m * m <= x) lo = m; else hi = m - 1n; } return lo; };
  const shaK = primes.map((q) => Number(icbrt(BigInt(q) << 96n) & 0xffffffffn));
  if (shaK[0] !== 0x428a2f98 || shaK[63] !== 0xc67178f2) throw new Error("SHA-256 constant self-check failed");
  lines.push(`(data (i32.const 0x7D00) "${shaK.map(u32).join("")}")`);
  lines.push(`(data (i32.const 0x8000) "${kpool}")`);
  for (const [name, [off, len]] of kOff) lines.push(`(global $K_${name} i32 (i32.const ${off})) (global $K_${name}_n i32 (i32.const ${len}))`);
  return lines.join("\n") + "\n";
}

export function selfCheck() {
  const { inv, pos } = ryuTables();
  const el = eiselLemireTable();
  const hi = (v: bigint) => v >> 64n;
  const checks: [string, boolean][] = [
    ["ryu inv[0] = 2^125+1", inv[0] === (1n << 125n) + 1n],
    ["ryu pos[0] = 2^124", pos[0] === 1n << 124n],
    ["ryu pos[1] hi = 1441151880758558720", hi(pos[1]) === 1441151880758558720n],
    ["EL 1e43 hi = 0xE596B7B0C643C719 (Go docs)", hi(el[43 + 348]) === 0xe596b7b0c643c719n],
    ["EL 1e0 = 2^127", el[348] === 1n << 127n],
    ["EL entries are 128-bit normalised", el.every((v) => bitlen(v) === 128)],
  ];
  // Regions must not overlap: [start, size].
  const regions: [string, number, number][] = [
    ["digits", 0x0100, 200], ["pow10", 0x0200, 23 * 8], ["names", 0x0300, 64 * 8], ["messages", 0x0500, 128 * 8],
    ["ryu inv", 0x2000, inv.length * 16], ["ryu pos", 0x3600, pos.length * 16], ["eisel-lemire", 0x4c00, el.length * 16], ["nibbles", 0x7800, 32],
  ];
  regions.sort((a, b) => a[1] - b[1]);
  for (let i = 1; i < regions.length; i++) {
    const [pn, ps, pl] = regions[i - 1];
    checks.push([`${pn} ends before ${regions[i][0]}`, ps + pl <= regions[i][1]]);
  }
  checks.push(["static data below the heap (0x10000)", 0x7800 + 32 <= 0x10000]);
  for (const [name, ok] of checks) if (!ok) throw new Error(`table self-check failed: ${name}`);
  return checks.length;
}

if (import.meta.main) {
  const n = selfCheck();
  const out = join(import.meta.dir, "..", "src/wat/_tables.gen.wat");
  mkdirSync(join(import.meta.dir, "..", "src/wat"), { recursive: true });
  writeFileSync(out, generate());
  console.log(`src/wat/_tables.gen.wat written (${n} self-checks passed)`);
}
