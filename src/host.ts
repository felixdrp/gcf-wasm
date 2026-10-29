// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
// Portions adapted from gcf-typescript, Copyright 2026 Dayna Blackwell / Blackwell
// Systems (Apache-2.0), and modified. See NOTICE.
//
// host.ts — JavaScript API for gcf.wasm (Bun, Node, browsers).
//
//   const gcf = await GcfCodec.instantiate(wasmBytes);
//   const text  = gcf.encode({ users: [{ id: 1, name: "Ada" }] });
//   const value = gcf.decode(text);
//
// Decoding: generic payloads cross the wasm boundary as JSON and are
// materialised with JSON.parse; non-delta graph payloads use the engine's
// columnar output (every string sent once, edges as indices) and are rebuilt
// here with the same shape and key order as the plain JSON output.
//
// Encoding: values are serialised with the native JSON.stringify (or taken
// as JSON text with encodeJson, which preserves exact key order), written
// straight into wasm memory with encodeInto, and encoded by the codec.
//
// Streaming encoders are small state machines that emit text as data
// arrives; they run in JavaScript (crossing into wasm per row would cost more
// than it saves) and use the same quoting rules as the engine, which the test
// suite cross-checks.

// ============================================================================
// Errors
// ============================================================================

/** Every engine failure carries the spec's error category (e.g. "count_mismatch"). */
export class GcfError extends Error {
  readonly code: string;
  readonly detail: string;
  readonly line: number;

  constructor(code: string, detail: string, line: number) {
    super(line > 0 ? `${code} (line ${line}): ${detail}` : `${code}: ${detail}`);
    this.name = "GcfError";
    this.code = code;
    this.detail = detail;
    this.line = line;
  }
}
/** @deprecated alias kept for older imports. */
export const GcfDecodeError = GcfError;
export type GcfDecodeError = GcfError;

// ============================================================================
// Types
// ============================================================================

/**
 * Policy for integers beyond ±(2^53-1), which a JS number cannot hold
 * exactly (SPEC §2.3.2). Default `'error'`.
 */
export type LargeIntMode = "error" | "string" | "bigint" | "number";

export interface DecodeOptions {
  largeInt?: LargeIntMode;
}

export interface EncodeOptions {
  /** Do not promote fixed-shape nested objects to `a>b` path columns. */
  noFlatten?: boolean;
}

export interface BytesOptions {
  /**
   * Return a zero-copy view into the engine's memory instead of a copy. The
   * view is only valid until the next call on the same codec (the arena is
   * reset and the memory may grow). Default: false (an owned copy).
   */
  view?: boolean;
}

/** Default `maxRetainedMemory`: 64 MiB. */
export const DEFAULT_MAX_RETAINED_MEMORY = 64 * 1024 * 1024;

export interface CodecOptions {
  /**
   * Bytes of WebAssembly memory a codec may keep reserved between calls.
   * A codec's memory grows to the largest payload it has handled and
   * WebAssembly memory cannot shrink, so when a call leaves more than this,
   * the codec prepares a fresh instance in the background and switches to
   * it as soon as the call has returned (asynchronously, never during a
   * call); the old memory is then garbage collected. Calls can still use
   * more while they run: this bounds what stays reserved afterwards, not
   * the peak.
   *
   * Default: 64 MiB (`DEFAULT_MAX_RETAINED_MEMORY`), which decoding up to
   * about 15 MB of GCF, or encoding up to about 15 MB of JSON, does not
   * reach. Above it, the first large call on the fresh instance is up to
   * about 25% slower while the memory is requested again, so if you handle
   * such payloads continuously, raise the limit or pass `Infinity` to keep
   * the memory.
   */
  maxRetainedMemory?: number;
}

export interface GraphSymbol {
  qualifiedName: string;
  kind: string;
  score: number;
  provenance: string;
  distance: number;
}

export interface GraphEdge {
  source: string;
  target: string;
  edgeType: string;
  status?: string;
}

export interface GraphPayload {
  tool?: string;
  tokenBudget?: number;
  tokensUsed?: number;
  packRoot?: string;
  symbols: GraphSymbol[];
  edges: GraphEdge[];
}

export interface GraphDelta {
  tool?: string;
  baseRoot: string;
  newRoot: string;
  removed: Pick<GraphSymbol, "qualifiedName" | "kind">[];
  added: (Omit<GraphSymbol, "distance"> & { distance?: number })[];
  removedEdges: GraphEdge[];
  addedEdges: GraphEdge[];
  deltaTokens?: number;
  fullTokens?: number;
}

/** A keyed record set for generic delta encoding (SPEC §10a). */
export interface GenericSet {
  name?: string;
  key: string;
  fields: string[];
  rows: Record<string, unknown>[];
}

export interface GenericDelta {
  tool?: string;
  key: string;
  fields: string[];
  baseRoot: string;
  newRoot: string;
  added?: Record<string, unknown>[];
  changed?: Record<string, unknown>[];
  removed?: unknown[];
  deltaTokens?: number;
  fullTokens?: number;
}

// ============================================================================
// Engine ABI
// ============================================================================

interface Exports {
  memory: WebAssembly.Memory;
  gcf_input_alloc(len: number): number;
  gcf_decode(len: number): number;
  gcf_decode_graph_columns(len: number): number;
  gcf_decode_tape(len: number): number;
  gcf_encode(len: number, flags: number): number;
  gcf_encode_graph(len: number): number;
  /** WAT build only (feature-detected): columnar graph input written by the host. */
  gcf_encode_graph_cols?: (len: number) => number;
  /** WAT build only: optional features (bit 0 graph columns, bit 1 JS-host numbers in gcf_encode). */
  gcf_features?: () => number;
  gcf_encode_graph_session(len: number): number;
  gcf_encode_graph_delta(len: number): number;
  gcf_encode_generic_full(len: number): number;
  gcf_encode_generic_delta(len: number): number;
  gcf_generic_diff(len: number): number;
  gcf_encode_grouped(len: number): number;
  gcf_pack_root(len: number): number;
  gcf_delta_verify(len: number): number;
  gcf_delta_decode_apply(len: number): number;
  gcf_graph_delta_apply(len: number): number;
  gcf_output_ptr(): number;
  gcf_output_len(): number;
  gcf_output_unsafe_ints(): number;
  gcf_error_name_ptr(): number;
  gcf_error_name_len(): number;
  gcf_error_message_ptr(): number;
  gcf_error_message_len(): number;
  gcf_error_line(): number;
}

type Columns = {
  tool: string;
  tokenBudget: number;
  tokensUsed: number;
  packRoot: string;
  unchanged?: boolean;
  session?: boolean;
  names: string[];
  kinds: string[];
  provs: string[];
  types: string[];
  statuses: string[];
  k: number[];
  p: number[];
  s: number[];
  d: number[];
  es: number[];
  et: number[];
  ty: number[];
  st: number[];
  references?: number[];
};

const utf8 = new TextEncoder();
const fromUtf8 = new TextDecoder();

/** First line of the payload is a non-delta graph header. */
function isPlainGraph(text: string): boolean {
  if (!text.startsWith("GCF profile=graph")) return false;
  const nl = text.indexOf("\n");
  const header = nl < 0 ? text : text.slice(0, nl);
  return !/ delta=true(\s|$)/.test(header);
}

/**
 * JSON text for any JSON value, including bigint (and Map, in key order).
 *
 * A JS `number` is a double, so the engine must see it as one (SPEC §2.3.2:
 * on encode the host type decides the token shape). JSON.stringify writes an
 * integral double >= 2^53 as bare digits, which the engine would read as an
 * exact int64, so such values are re-serialised in exponent form. The fast
 * path stays native: the slower walk only runs when the text holds a 16+
 * digit integer token (or a bigint/Map is present).
 */
function toJsonText(value: unknown): string {
  try {
    const s = JSON.stringify(value);
    // Only an *integer* token of 16+ digits can be an integral double >= 2^53
    // (fractions and exponents are already double-shaped).
    if (s !== undefined && !/(?<![\d.eE+-])-?\d{16,}(?![\d.eE])/.test(s)) return s;
  } catch {
    // BigInt (TypeError) — fall through to the general serialiser.
  }
  // Same shape as JSON.stringify: toJSON is honoured; in objects, undefined,
  // function and symbol members are omitted; in arrays they and holes are null.
  const skip = (v: unknown) => v === undefined || typeof v === "function" || typeof v === "symbol";
  const walk = (v0: unknown, key: string): string => {
    const v = v0 !== null && typeof v0 === "object" && typeof (v0 as { toJSON?: unknown }).toJSON === "function" ? (v0 as { toJSON(k: string): unknown }).toJSON(key) : v0;
    if (typeof v === "bigint") return v.toString();
    if (typeof v === "number" && Number.isInteger(v) && Math.abs(v) >= 9007199254740992) return v.toExponential();
    if (v === null || skip(v) || typeof v === "number" || typeof v === "boolean" || typeof v === "string") return skip(v) ? "null" : JSON.stringify(v);
    if (Array.isArray(v)) {
      const items: string[] = [];
      for (let i = 0; i < v.length; i++) items.push(skip(v[i]) ? "null" : walk(v[i], String(i)));
      return `[${items.join(",")}]`;
    }
    const entries = v instanceof Map ? [...v.entries()] : Object.entries(v as object);
    return `{${entries.filter(([, x]) => !skip(x)).map(([k, x]) => `${JSON.stringify(String(k))}:${walk(x, String(k))}`).join(",")}}`;
  };
  return walk(value, "");
}

/** A plain object (Object or null prototype, no toJSON): JSON.stringify reads its own properties. */
function isPlainRecord(v: unknown): v is Record<string, unknown> {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return false;
  const proto = Object.getPrototypeOf(v);
  return (proto === Object.prototype || proto === null) && (v as { toJSON?: unknown }).toJSON === undefined;
}

/** UTF-8 length of a string, or -1 when it holds a lone surrogate. */
function utf8LengthStrict(s: string): number {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff) {
      const d = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
      if (d < 0xdc00 || d > 0xdfff) return -1;
      n += 4;
      i++;
    } else if (c >= 0xdc00 && c <= 0xdfff) return -1;
    else n += 3;
  }
  return n;
}

/** JSON.parse that keeps integers beyond ±(2^53-1) exact, as string or bigint. */
function parseLargeInts(text: string, mode: "string" | "bigint"): unknown {
  let i = 0;
  const ws = () => {
    while (i < text.length && (text[i] === " " || text[i] === "\n" || text[i] === "\r" || text[i] === "\t")) i++;
  };
  const value = (): unknown => {
    ws();
    const c = text[i];
    if (c === "{") {
      i++;
      const o: Record<string, unknown> = {};
      ws();
      if (text[i] === "}") {
        i++;
        return o;
      }
      for (;;) {
        ws();
        const k = value() as string;
        ws();
        i++; // ':'
        o[k] = value();
        ws();
        if (text[i++] === "}") return o;
      }
    }
    if (c === "[") {
      i++;
      const a: unknown[] = [];
      ws();
      if (text[i] === "]") {
        i++;
        return a;
      }
      for (;;) {
        a.push(value());
        ws();
        if (text[i++] === "]") return a;
      }
    }
    if (c === '"') {
      const start = i++;
      while (text[i] !== '"') i += text[i] === "\\" ? 2 : 1;
      i++;
      return JSON.parse(text.slice(start, i));
    }
    const start = i;
    while (i < text.length && !",}] \n\r\t".includes(text[i])) i++;
    const lex = text.slice(start, i);
    if (lex === "true") return true;
    if (lex === "false") return false;
    if (lex === "null") return null;
    if (/^-?\d+$/.test(lex)) {
      const n = Number(lex);
      if (!Number.isSafeInteger(n)) return mode === "bigint" ? BigInt(lex) : lex;
      return n;
    }
    return Number(lex);
  };
  return value();
}

// ============================================================================
// Codec
// ============================================================================

export class GcfCodec {
  private x: Exports;
  private readonly module: WebAssembly.Module;
  private readonly maxRetained: number;
  /** A fresh instance being prepared; it replaces the current one when ready. */
  private pending: Promise<void> | undefined;

  private constructor(module: WebAssembly.Module, exports: Exports, opts: CodecOptions) {
    this.module = module;
    this.x = exports;
    const max = opts.maxRetainedMemory ?? DEFAULT_MAX_RETAINED_MEMORY;
    if (!(max > 0)) throw new RangeError(`maxRetainedMemory must be a positive number of bytes or Infinity, got ${max}`);
    this.maxRetained = max;
  }

  static async instantiate(wasm: BufferSource | WebAssembly.Module, opts: CodecOptions = {}): Promise<GcfCodec> {
    const module = wasm instanceof WebAssembly.Module ? wasm : await WebAssembly.compile(wasm);
    const instance = await WebAssembly.instantiate(module, {});
    return new GcfCodec(module, instance.exports as unknown as Exports, opts);
  }

  /** The current instance's exports (the raw ABI, docs/WASM_ABI.md). */
  get exports(): Exports {
    return this.x;
  }

  /** Bytes of WebAssembly memory the codec currently holds. */
  get memoryBytes(): number {
    return this.x.memory.buffer.byteLength;
  }

  /**
   * Replace the instance with a fresh one, releasing the memory it holds
   * (see `maxRetainedMemory`, which does this automatically). Results of
   * earlier calls stay valid, including `view: true` byte views.
   */
  recycle(): Promise<void> {
    // Every codec method is synchronous, so this continuation never runs in
    // the middle of a call: the switch always happens between calls.
    this.pending ??= WebAssembly.instantiate(this.module, {}).then((instance) => {
      this.x = instance.exports as unknown as Exports;
      this.pending = undefined;
    });
    return this.pending;
  }

  // ---- plumbing -----------------------------------------------------------------

  /** Copy the input into the engine's arena and return its byte length. */
  private load(input: string | Uint8Array): number {
    const x = this.exports;
    if (typeof input !== "string") {
      const ptr = x.gcf_input_alloc(input.length);
      new Uint8Array(x.memory.buffer, ptr, input.length).set(input);
      return input.length;
    }
    // UTF-8 needs at most 3 bytes per UTF-16 code unit; encode straight into
    // wasm memory instead of allocating an intermediate Uint8Array.
    const cap = input.length * 3;
    const ptr = x.gcf_input_alloc(cap);
    return utf8.encodeInto(input, new Uint8Array(x.memory.buffer, ptr, cap)).written;
  }

  /**
   * Every call ends by reading its result through output() or outputBytes().
   * When the call left more memory than `maxRetainedMemory`, a fresh
   * instance is prepared; it takes over once the call has returned.
   */
  private releaseIfLarge(): void {
    if (!this.pending && this.x.memory.buffer.byteLength > this.maxRetained) void this.recycle();
  }

  private output(status: number): string {
    this.releaseIfLarge();
    const x = this.exports;
    const text = (p: number, n: number) => fromUtf8.decode(new Uint8Array(x.memory.buffer, p, n));
    if (status !== 0) {
      throw new GcfError(
        text(x.gcf_error_name_ptr(), x.gcf_error_name_len()),
        text(x.gcf_error_message_ptr(), x.gcf_error_message_len()),
        x.gcf_error_line(),
      );
    }
    return text(x.gcf_output_ptr(), x.gcf_output_len());
  }

  /** Raw output bytes: an owned copy, or a view valid until the next call. */
  private outputBytes(status: number, view: boolean): Uint8Array {
    this.releaseIfLarge();
    if (status !== 0) this.output(status); // throws GcfError
    const x = this.exports;
    const bytes = new Uint8Array(x.memory.buffer, x.gcf_output_ptr(), x.gcf_output_len());
    return view ? bytes : bytes.slice();
  }

  private run(fn: (len: number) => number, input: string): string {
    return this.output(fn.call(this.exports, this.load(input)));
  }

  /** JSON.parse with the large-integer policy applied (SPEC §2.3.2). */
  private parse(json: string, mode: LargeIntMode): unknown {
    if (!this.exports.gcf_output_unsafe_ints() || mode === "number") return JSON.parse(json);
    if (mode === "error") {
      const m = /-?\d{16,}/.exec(json);
      throw new GcfError(
        "unsafe_integer",
        `integer ${m ? m[0] : ""} exceeds the safe-integer range (2^53-1) of a JavaScript number; decode with largeInt 'string' | 'bigint' | 'number', or model the value as a string`,
        0,
      );
    }
    return parseLargeInts(json, mode);
  }

  // ---- decoding -----------------------------------------------------------------

  /** Decode to the spec-shaped JSON text (exact integers, no policy needed). */
  decodeToJson(input: string | Uint8Array): string {
    return this.output(this.exports.gcf_decode(this.load(input)));
  }

  /** Decode to a JS value. */
  decode(input: string | Uint8Array, opts: DecodeOptions = {}): unknown {
    const mode = opts.largeInt ?? "error";
    if (typeof input === "string" && isPlainGraph(input)) {
      const cols = this.parse(this.output(this.exports.gcf_decode_graph_columns(this.load(input))), mode) as Columns;
      return GcfCodec.graphFromColumns(cols);
    }
    return this.parse(this.decodeToJson(input), mode);
  }

  /**
   * Lazy decode: returns objects and arrays that look and behave like plain
   * JS values (property access, `Object.keys`, iteration, `JSON.stringify`)
   * but convert each value only when it is read. The engine writes a compact
   * binary tape (numbers in binary, strings in a byte pool, keys interned)
   * that is copied out of wasm memory, so the result stays valid after later
   * codec calls. Use it when you read part of a document; `toPlain(value)`
   * converts a lazy value (or any sub-tree) into ordinary JS objects.
   */
  decodeLazy(input: string | Uint8Array, opts: DecodeOptions = {}): unknown {
    const tape = this.outputBytes(this.exports.gcf_decode_tape(this.load(input)), false);
    return new LazyTape(tape.buffer as ArrayBuffer, opts.largeInt ?? "error").root();
  }

  /** Rebuild `{tool, tokenBudget, tokensUsed, packRoot, ..., symbols, edges}`. */
  static graphFromColumns(c: Columns): unknown {
    const { names, kinds, provs, types, statuses, k, p, s, d, es, et, ty, st } = c;
    const n = k.length;
    const symbols = new Array(n);
    for (let i = 0; i < n; i++) {
      symbols[i] = { qualifiedName: names[i], kind: kinds[k[i]], score: s[i], provenance: provs[p[i]], distance: d[i] };
    }
    const m = es.length;
    const edges = new Array(m);
    for (let j = 0; j < m; j++) {
      edges[j] = { source: names[es[j]], target: names[et[j]], edgeType: types[ty[j]], status: statuses[st[j]] };
    }
    const out: Record<string, unknown> = { tool: c.tool, tokenBudget: c.tokenBudget, tokensUsed: c.tokensUsed, packRoot: c.packRoot };
    if (c.unchanged) out.unchanged = true;
    if (c.session) out.session = true;
    out.symbols = symbols;
    out.edges = edges;
    if (c.references) out.references = c.references;
    return out;
  }

  // ---- bytes in, bytes out (no JS strings) ------------------------------------
  //
  // For servers and pipelines whose data is already bytes (request bodies,
  // files, sockets): skips TextEncoder/TextDecoder and JSON.parse/stringify
  // entirely. See docs/JS_WASM_BOUNDARY.md.

  /** JSON bytes (UTF-8) -> GCF bytes. `profile: "graph"` for graph payloads. */
  encodeJsonBytes(json: Uint8Array | string, opts: EncodeOptions & BytesOptions & { profile?: "generic" | "graph" } = {}): Uint8Array {
    const len = this.load(json);
    const status = opts.profile === "graph" ? this.exports.gcf_encode_graph(len) : this.exports.gcf_encode(len, opts.noFlatten ? 1 : 0);
    return this.outputBytes(status, opts.view ?? false);
  }

  /** GCF bytes -> spec-shaped JSON bytes (exact integers, no policy needed). */
  decodeToJsonBytes(gcf: Uint8Array | string, opts: BytesOptions = {}): Uint8Array {
    return this.outputBytes(this.exports.gcf_decode(this.load(gcf)), opts.view ?? false);
  }

  // ---- encoding -----------------------------------------------------------------

  /** Encode any JSON value (object, array or scalar) as generic-profile GCF. */
  encode(value: unknown, opts: EncodeOptions = {}): string {
    // WAT module: plain JSON.stringify output goes straight in with flag bit 1
    // ("JS-host numbers": an integer token of magnitude >= 2^53 is a double),
    // so the 16+ digit integer scan of toJsonText is not needed. Values that
    // JSON.stringify cannot serialise (bigint) still take toJsonText.
    const x = this.exports;
    if (x.gcf_features && (x.gcf_features() & 2) !== 0) {
      let text: string | undefined;
      try {
        text = JSON.stringify(value);
      } catch {
        text = undefined;
      }
      if (text !== undefined) return this.output(x.gcf_encode(this.load(text), (opts.noFlatten ? 1 : 0) | 2));
    }
    return this.encodeJson(toJsonText(value), opts);
  }

  /**
   * Encode JSON *text*. Use this when key order matters exactly: JS objects
   * move integer-like keys ("5", "3") to the front, JSON text does not.
   */
  encodeJson(json: string, opts: EncodeOptions = {}): string {
    return this.output(this.exports.gcf_encode(this.load(json), opts.noFlatten ? 1 : 0));
  }

  /** Graph payload (buffered, canonical ordering, SPEC §16.1). */
  encodeGraph(payload: GraphPayload): string {
    // Columnar fast path (WAT module): no JSON.stringify and no JSON parsing
    // in wasm. It returns null whenever JSON.stringify could see the payload
    // differently, and the JSON path takes over; both give the same bytes.
    if (this.exports.gcf_encode_graph_cols) {
      const out = this.encodeGraphColumns(payload);
      if (out !== null) return out;
    }
    return this.run(this.exports.gcf_encode_graph, toJsonText(payload));
  }

  /**
   * Write the graph as columns into wasm memory (layout: gcf_encode_graph_cols
   * in src/wat/13_graph_enc.wat): a 48-byte header, 40 bytes per symbol
   * (score, distance as f64; qualifiedName, kind, provenance as string
   * offset/length), 32 bytes per edge (source, target, edgeType, status),
   * then every string, encoded with a single encodeInto call.
   *
   * Field values follow the JSON path exactly: a non-string is "", a
   * non-number or a non-finite number is 0, -0 is 0. Anything that
   * JSON.stringify would not read the same way (a non-plain object, toJSON,
   * a bigint, an object in a recognised field, a string with a lone
   * surrogate) returns null. One difference remains by design: members the
   * graph encoding never reads (extra fields) are not inspected, so an
   * ill-formed string there is rejected by the JSON path (invalid_surrogate)
   * but ignored here.
   */
  private encodeGraphColumns(p: GraphPayload): string | null {
    if (!isPlainRecord(p)) return null;
    const syms: unknown[] = Array.isArray(p.symbols) && (p.symbols as { toJSON?: unknown }).toJSON === undefined ? p.symbols : [];
    const edges: unknown[] = Array.isArray(p.edges) && (p.edges as { toJSON?: unknown }).toJSON === undefined ? p.edges : [];
    const ns = syms.length;
    const ne = edges.length;
    const parts: string[] = new Array(2 + 3 * ns + 4 * ne);
    const nums = new Float64Array(2 + 2 * ns);
    let k = 0;
    // A recognised field holding an object, or a string with a lone surrogate
    // where a number belongs, would make the JSON path read (or reject)
    // something else: bail out to it.
    let bail = false;
    const str = (v: unknown) => {
      if (typeof v === "string") return v;
      if (v !== null && typeof v === "object") bail = true;
      return "";
    };
    const num = (v: unknown) => {
      if (typeof v === "number") return Number.isFinite(v) && v !== 0 ? v : 0;
      if (typeof v === "bigint" || (v !== null && typeof v === "object") || (typeof v === "string" && utf8LengthStrict(v) < 0)) bail = true;
      return 0;
    };
    parts[k++] = str(p.tool);
    parts[k++] = str(p.packRoot);
    nums[0] = num(p.tokenBudget);
    nums[1] = num(p.tokensUsed);
    for (let i = 0; i < ns; i++) {
      const s = syms[i] as Record<string, unknown>;
      if (s !== null && typeof s === "object" && !Array.isArray(s)) {
        if (!isPlainRecord(s)) return null;
        parts[k++] = str(s.qualifiedName);
        parts[k++] = str(s.kind);
        parts[k++] = str(s.provenance);
        nums[2 + 2 * i] = num(s.score);
        nums[3 + 2 * i] = num(s.distance);
      } else {
        parts[k++] = "";
        parts[k++] = "";
        parts[k++] = "";
      }
    }
    for (let i = 0; i < ne; i++) {
      const e = edges[i] as Record<string, unknown>;
      if (e !== null && typeof e === "object" && !Array.isArray(e)) {
        if (!isPlainRecord(e)) return null;
        parts[k++] = str(e.source);
        parts[k++] = str(e.target);
        parts[k++] = str(e.edgeType);
        parts[k++] = str(e.status);
      } else {
        parts[k++] = "";
        parts[k++] = "";
        parts[k++] = "";
        parts[k++] = "";
      }
    }
    if (bail) return null;
    const joined = parts.join("");
    const head = 48 + 40 * ns + 32 * ne;
    const cap = head + 3 * joined.length;
    const x = this.exports;
    const ptr = x.gcf_input_alloc(cap);
    const buf = x.memory.buffer;
    const written = utf8.encodeInto(joined, new Uint8Array(buf, ptr + head, cap - head)).written;
    // String offsets: UTF-16 lengths when everything is ASCII (one encodeInto
    // byte per code unit), otherwise exact UTF-8 lengths.
    const lens = new Uint32Array(parts.length);
    if (written === joined.length) {
      for (let i = 0; i < parts.length; i++) lens[i] = parts[i].length;
    } else {
      for (let i = 0; i < parts.length; i++) {
        const n = utf8LengthStrict(parts[i]);
        if (n < 0) return null; // lone surrogate: JSON.stringify escapes it and the engine rejects it
        lens[i] = n;
      }
    }
    const u32 = new Uint32Array(buf, ptr, head >>> 2);
    const f64 = new Float64Array(buf, ptr, head >>> 3);
    u32[0] = 0x47464347; // "GCFG"
    u32[1] = ns;
    u32[2] = ne;
    u32[3] = head;
    let off = 0;
    let j = 0;
    const put = (at: number) => {
      u32[at] = off;
      u32[at + 1] = lens[j];
      off += lens[j++];
    };
    put(4);
    put(6);
    f64[4] = nums[0];
    f64[5] = nums[1];
    for (let i = 0; i < ns; i++) {
      f64[6 + 5 * i] = nums[2 + 2 * i];
      f64[7 + 5 * i] = nums[3 + 2 * i];
      const w = 16 + 10 * i;
      put(w);
      put(w + 2);
      put(w + 4);
    }
    const e0 = 12 + 10 * ns;
    for (let i = 0; i < ne; i++) {
      const w = e0 + 8 * i;
      put(w);
      put(w + 2);
      put(w + 4);
      put(w + 6);
    }
    return this.output(x.gcf_encode_graph_cols!(head + written));
  }

  /** Graph delta payload (SPEC §10.1). */
  encodeGraphDelta(delta: GraphDelta): string {
    return this.run(this.exports.gcf_encode_graph_delta, toJsonText(delta));
  }

  /** Opt-in value-grouped keyed set (SPEC §7.4.8). */
  encodeGrouped(data: Record<string, unknown>[], keyField: string, groupField: string): string {
    return this.run(this.exports.gcf_encode_grouped, toJsonText({ data, keyField, groupField }));
  }

  /** Delta-participating full payload for a keyed set (SPEC §10a.1). */
  encodeGenericFull(set: GenericSet, tool = ""): string {
    return this.run(this.exports.gcf_encode_generic_full, toJsonText({ set, tool }));
  }

  /** Encode an explicit generic delta payload (SPEC §10a.2). */
  encodeGenericDelta(delta: GenericDelta): string {
    return this.run(this.exports.gcf_encode_generic_delta, toJsonText(delta));
  }

  /**
   * Diff two keyed sets and encode the delta (added / changed / removed,
   * sorted by identity). Throws GcfError("invalid_input") on a schema change:
   * send a full payload instead (SPEC §10a.7).
   */
  encodeGenericDiff(base: GenericSet, next: GenericSet, opts: { tool?: string; deltaTokens?: number; fullTokens?: number } = {}): string {
    return this.run(this.exports.gcf_generic_diff, toJsonText({ base, next, ...opts }));
  }

  // ---- roots and delta verification -----------------------------------------------

  /** `gcf-pack-root-v1`: graph `{symbols, edges}` or keyed set `{fields, rows}`. */
  packRoot(input: Pick<GraphPayload, "symbols" | "edges"> | Pick<GenericSet, "rows"> & Partial<GenericSet>): string {
    return this.run(this.exports.gcf_pack_root, toJsonText(input));
  }

  /** Apply a generic delta wire to a base set atomically; returns the new root. */
  applyGenericDelta(wire: string, base: GenericSet, expectedNewRoot?: string): string {
    return this.run(this.exports.gcf_delta_decode_apply, toJsonText({ wire, base, expectedNewRoot }));
  }

  /** Apply a graph delta wire to a base snapshot; returns the new root and snapshot. */
  applyGraphDelta(wire: string, base: Pick<GraphPayload, "symbols" | "edges">): { root: string; snapshot: Pick<GraphPayload, "symbols" | "edges"> } {
    return JSON.parse(this.run(this.exports.gcf_graph_delta_apply, toJsonText({ wire, base })));
  }

  /** @internal used by GraphSession */
  encodeGraphSessionRaw(payload: GraphPayload, known: Record<string, number>, next: number): string {
    return this.run(this.exports.gcf_encode_graph_session, toJsonText({ payload, known, next }));
  }
}

/** @deprecated alias kept for older imports. */
export const GcfDecoder = GcfCodec;
export type GcfDecoder = GcfCodec;

// ============================================================================
// Sessions
// ============================================================================

/**
 * Graph session deduplication (SPEC §9): symbols sent in an earlier call are
 * re-sent as bare `@id  # previously transmitted` references with stable IDs.
 */
export class GraphSession {
  private ids = new Map<string, number>();
  private nextId = 0;
  private readonly codec: GcfCodec;

  constructor(codec: GcfCodec) {
    this.codec = codec;
  }

  encode(payload: GraphPayload): string {
    const known: Record<string, number> = {};
    for (const s of payload.symbols) {
      const id = this.ids.get(s.qualifiedName);
      if (id !== undefined) known[s.qualifiedName] = id;
    }
    const wire = this.codec.encodeGraphSessionRaw(payload, known, this.nextId);
    for (const s of payload.symbols) {
      if (!this.ids.has(s.qualifiedName)) this.ids.set(s.qualifiedName, this.nextId++);
    }
    return wire;
  }

  get size(): number {
    return this.ids.size;
  }

  reset(): void {
    this.ids.clear();
    this.nextId = 0;
  }
}

export type ReanchorPolicy = { mode: "fixedN"; n: number } | { mode: "sizeGuard" };
export const DEFAULT_REANCHOR_N = 15;

function utf8Length(s: string): number {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff) {
      n += 4;
      i++;
    } else n += 3;
  }
  return n;
}

/**
 * Producer-side delta session with re-anchoring (SPEC §10a.8): emits deltas
 * against the previous turn and, per policy, a full payload every N turns
 * (`fixedN`) or when accumulated deltas reach a full payload's size
 * (`sizeGuard`). A schema change always re-anchors.
 */
export class GenericDeltaSession {
  private turnCount = 0;
  private cum = 0;
  private policy: ReanchorPolicy;
  private readonly codec: GcfCodec;
  private base: GenericSet;
  private readonly tool: string;

  constructor(codec: GcfCodec, base: GenericSet, tool = "", policy: ReanchorPolicy = { mode: "fixedN", n: DEFAULT_REANCHOR_N }) {
    this.codec = codec;
    this.base = base;
    this.tool = tool;
    this.policy = policy.mode === "fixedN" && policy.n <= 0 ? { mode: "fixedN", n: DEFAULT_REANCHOR_N } : policy;
  }

  currentFull(): string {
    return this.codec.encodeGenericFull(this.base, this.tool);
  }

  turn(): number {
    return this.turnCount;
  }

  next(nextSet: GenericSet): { wire: string; isFull: boolean } {
    this.turnCount++;
    const sameSchema =
      nextSet.key === this.base.key && nextSet.fields.length === this.base.fields.length && nextSet.fields.every((f, i) => f === this.base.fields[i]);
    if (!sameSchema) return { wire: this.reanchor(nextSet), isFull: true };
    // Delta wires carry no tool= field; only full payloads do (reference behaviour).
    const deltaWire = this.codec.encodeGenericDiff(this.base, nextSet);
    const reanchor =
      this.policy.mode === "sizeGuard"
        ? this.cum + utf8Length(deltaWire) >= utf8Length(this.codec.encodeGenericFull(nextSet, this.tool))
        : this.turnCount % this.policy.n === 0;
    if (reanchor) return { wire: this.reanchor(nextSet), isFull: true };
    this.base = nextSet;
    this.cum += utf8Length(deltaWire);
    return { wire: deltaWire, isFull: false };
  }

  private reanchor(nextSet: GenericSet): string {
    this.base = nextSet;
    this.cum = 0;
    return this.codec.encodeGenericFull(nextSet, this.tool);
  }
}

// ============================================================================
// Lazy decoding: reader for the binary tape of src/wat/12_tape.wat (TapeWriter in gcf-zig)
// ============================================================================

const TAPE_HEADER = 20;
const textDecoder = new TextDecoder();
/** Lazy proxy -> [tape, node index], for toPlain(). */
const lazyNodes = new WeakMap<object, [LazyTape, number]>();

class LazyTape {
  private readonly w: Uint32Array;
  private readonly pool: Uint8Array;
  private readonly dv: DataView;
  private readonly rootIndex: number;
  private readonly keyText = new Map<number, string>(); // pool offset -> key
  private readonly keyOffset = new Map<string, number>(); // key -> pool offset
  private readonly proxies = new Map<number, object>(); // node -> proxy
  private readonly largeInt: LargeIntMode;

  constructor(buf: ArrayBuffer, largeInt: LargeIntMode) {
    this.largeInt = largeInt;
    const h = new Uint32Array(buf, 0, 5);
    if (h[0] !== 0x54464347 || h[1] !== 1) throw new GcfError("invalid_input", "not a GCF tape", 0);
    this.rootIndex = h[2];
    this.w = new Uint32Array(buf, TAPE_HEADER, h[3]);
    this.pool = new Uint8Array(buf, TAPE_HEADER + h[3] * 4, h[4]);
    this.dv = new DataView(buf);
  }

  root(): unknown {
    return this.value(this.rootIndex);
  }

  /** UTF-8 slice of the pool -> string (short ASCII strings without TextDecoder). */
  private text(off: number, len: number): string {
    const p = this.pool;
    if (len <= 24) {
      let s = "";
      for (let i = off, end = off + len; i < end; i++) {
        const b = p[i];
        if (b >= 0x80) return textDecoder.decode(p.subarray(off, off + len));
        s += String.fromCharCode(b);
      }
      return s;
    }
    return textDecoder.decode(p.subarray(off, off + len));
  }

  private key(off: number, len: number): string {
    let k = this.keyText.get(off);
    if (k === undefined) {
      k = this.text(off, len);
      this.keyText.set(off, k);
      this.keyOffset.set(k, off);
    }
    return k;
  }

  private int64(i: number): number | bigint | string {
    const lo = this.w[i + 1];
    const hi = this.w[i + 2] | 0;
    const n = hi * 4294967296 + lo;
    if (Number.isSafeInteger(n)) return n;
    const big = (BigInt(hi) << 32n) | BigInt(lo);
    switch (this.largeInt) {
      case "bigint":
        return big;
      case "string":
        return big.toString();
      case "number":
        return Number(big);
      default:
        throw new GcfError("unsafe_integer", `integer ${big} exceeds the safe-integer range (2^53-1) of a JavaScript number; decode with largeInt 'string' | 'bigint' | 'number'`, 0);
    }
  }

  value(i: number): unknown {
    const h = this.w[i];
    switch (h & 15) {
      case 0:
        return null;
      case 1:
        return false;
      case 2:
        return true;
      case 3:
        return (h | 0) >> 4;
      case 4:
        return this.int64(i);
      case 5:
        return this.dv.getFloat64(TAPE_HEADER + (i + 1) * 4, true);
      case 6:
        return this.text(this.w[i + 1], h >>> 4);
      default: {
        let p = this.proxies.get(i);
        if (p === undefined) {
          p = (h & 15) === 7 ? this.arrayProxy(i) : this.objectProxy(i);
          this.proxies.set(i, p);
          lazyNodes.set(p, [this, i]);
        }
        return p;
      }
    }
  }

  /** Child node of object `i` named `name`, or -1. Known names match by pool offset. */
  private find(i: number, name: string): number {
    const n = this.w[i] >>> 4;
    const base = i + 1;
    const w = this.w;
    const off = this.keyOffset.get(name);
    if (off !== undefined) {
      for (let k = 0, j = base; k < n; k++, j += 3) if (w[j] === off) return w[j + 2];
      return -1;
    }
    for (let k = 0, j = base; k < n; k++, j += 3) {
      if (this.key(w[j], w[j + 1]) === name) return w[j + 2];
    }
    return -1;
  }

  private keys(i: number): string[] {
    const n = this.w[i] >>> 4;
    const out = new Array<string>(n);
    for (let k = 0, j = i + 1; k < n; k++, j += 3) out[k] = this.key(this.w[j], this.w[j + 1]);
    return out;
  }

  private objectProxy(i: number): object {
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    const tape = this;
    const readOnly = () => false;
    return new Proxy(
      {},
      {
        get(t, prop, receiver) {
          if (typeof prop === "string") {
            const c = tape.find(i, prop);
            if (c >= 0) return tape.value(c);
          }
          return Reflect.get(t, prop, receiver);
        },
        has(t, prop) {
          return (typeof prop === "string" && tape.find(i, prop) >= 0) || Reflect.has(t, prop);
        },
        ownKeys() {
          return tape.keys(i);
        },
        getOwnPropertyDescriptor(_t, prop) {
          if (typeof prop !== "string") return undefined;
          const c = tape.find(i, prop);
          return c < 0 ? undefined : { value: tape.value(c), writable: false, enumerable: true, configurable: true };
        },
        set: readOnly,
        defineProperty: readOnly,
        deleteProperty: readOnly,
      },
    );
  }

  private arrayProxy(i: number): object {
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    const tape = this;
    const n = this.w[i] >>> 4;
    const index = (prop: string | symbol): number => {
      if (typeof prop !== "string" || prop.length === 0) return -1;
      const c = prop.charCodeAt(0);
      if (c < 48 || c > 57) return -1;
      const k = Number(prop);
      return Number.isInteger(k) && k < n && String(k) === prop ? k : -1;
    };
    const readOnly = () => false;
    return new Proxy(new Array(n), {
      get(t, prop, receiver) {
        const k = index(prop);
        if (k >= 0) return tape.value(tape.w[i + 1 + k]);
        return Reflect.get(t, prop, receiver);
      },
      has(t, prop) {
        return index(prop) >= 0 || Reflect.has(t, prop);
      },
      ownKeys() {
        const keys: string[] = new Array(n + 1);
        for (let k = 0; k < n; k++) keys[k] = String(k);
        keys[n] = "length";
        return keys;
      },
      getOwnPropertyDescriptor(t, prop) {
        const k = index(prop);
        if (k >= 0) return { value: tape.value(tape.w[i + 1 + k]), writable: false, enumerable: true, configurable: true };
        return Reflect.getOwnPropertyDescriptor(t, prop);
      },
      set: readOnly,
      defineProperty: readOnly,
      deleteProperty: readOnly,
    });
  }

  /** Materialise node `i` as plain JS values, walking the tape directly. */
  plain(i: number): unknown {
    const h = this.w[i];
    const tag = h & 15;
    if (tag === 7) {
      const n = h >>> 4;
      const out = new Array(n);
      for (let k = 0; k < n; k++) out[k] = this.plain(this.w[i + 1 + k]);
      return out;
    }
    if (tag === 8) {
      const n = h >>> 4;
      const out: Record<string, unknown> = {};
      for (let k = 0, j = i + 1; k < n; k++, j += 3) out[this.key(this.w[j], this.w[j + 1])] = this.plain(this.w[j + 2]);
      return out;
    }
    return this.value(i);
  }
}

/** Convert a value from `decodeLazy` (or any part of it) to plain JS values. */
export function toPlain(value: unknown): unknown {
  if (value === null || typeof value !== "object") return value;
  const node = lazyNodes.get(value);
  return node ? node[0].plain(node[1]) : value;
}

// ============================================================================
// Scalar formatting (JavaScript port of the engine's rules, SPEC §2.4)
// ============================================================================

const JSON_NUMBER_RE = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
const NUMERIC_LIKE_RE = /^[+-]\.?\d|^\.\d|^0\d/;
const INLINE_ARRAY_RE = /\[[^\]]*\][ \t\n\v\f\r]*:/;
const BARE_KEY_RE = /^[a-zA-Z_][a-zA-Z0-9_]*$/;

/** True when a string must be quoted (SPEC §2.4). */
export function needsQuote(s: string): boolean {
  if (s === "" || s === "-" || s === "~" || s === "^" || s === "true" || s === "false") return true;
  if (s.length >= 3 && s[0] === "^" && s[1] === "{" && s[s.length - 1] === "}") return true;
  if (JSON_NUMBER_RE.test(s) || NUMERIC_LIKE_RE.test(s)) return true;
  if (s[0] === " " || s[s.length - 1] === " " || s[0] === "#" || s[0] === "@" || s[0] === ".") return true;
  if (INLINE_ARRAY_RE.test(s)) return true;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 0x22 || c === 0x5c || c < 0x20 || c === 0x7c || c === 0x2c) return true;
    if (c >= 0x80 && (c <= 0xa0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a) || c === 0x2028 || c === 0x2029 || c === 0x202f || c === 0x205f || c === 0x3000 || c === 0xfeff)) return true;
  }
  return false;
}

/** JSON-compatible quoted string with the canonical escapes (SPEC §2.2). */
export function quoteString(s: string): string {
  let out = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 0x22) out += '\\"';
    else if (c === 0x5c) out += "\\\\";
    else if (c === 0x08) out += "\\b";
    else if (c === 0x0c) out += "\\f";
    else if (c === 0x0a) out += "\\n";
    else if (c === 0x0d) out += "\\r";
    else if (c === 0x09) out += "\\t";
    else if (c < 0x20) out += "\\u" + c.toString(16).padStart(4, "0");
    else out += s[i];
  }
  return out + '"';
}

/** Key grammar (SPEC §2a): bare when valid, otherwise quoted. */
export function formatKey(k: string): string {
  return BARE_KEY_RE.test(k) ? k : quoteString(k);
}

const I64_MIN = -9223372036854775808n;
const I64_MAX = 9223372036854775807n;

/** Canonical number (SPEC §2.3.1). */
export function formatNumber(f: number): string {
  if (!Number.isFinite(f)) throw new GcfError("invalid_input", `non-finite number ${f} is outside the JSON data model`, 0);
  if (f === 0) return "0";
  const a = Math.abs(f);
  if (a >= 1e-6 && a < 9007199254740992) return String(f);
  return f.toExponential().replace(/e\+?0*(\d)/, "e+$1").replace(/e-0*(\d)/, "e-$1");
}

/** Canonical scalar: null `-`, booleans, numbers, strings quoted when needed. */
export function formatScalar(v: unknown): string {
  if (v === null || v === undefined) return "-";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return formatNumber(v);
  if (typeof v === "bigint") {
    if (v < I64_MIN || v > I64_MAX) throw new GcfError("out_of_range", `integer ${v} is outside int64; model it as a string`, 0);
    return v.toString();
  }
  const s = String(v);
  return needsQuote(s) ? quoteString(s) : s;
}

/** Graph score: two decimals, round-half-to-even on the exact double (SPEC §5). */
export function formatScore(x: number): string {
  if (!Number.isFinite(x)) return "0.00";
  const neg = x < 0;
  const exact = Math.abs(x).toFixed(20); // exact enough to decide the tie
  const dot = exact.indexOf(".");
  const keep = exact.slice(dot + 1, dot + 3);
  const rest = exact.slice(dot + 3);
  const first = rest.charCodeAt(0) - 48;
  const up = first > 5 || (first === 5 && (/[1-9]/.test(rest.slice(1)) || (keep.charCodeAt(1) - 48) % 2 === 1));
  let cents = parseInt(exact.slice(0, dot), 10) * 100 + parseInt(keep, 10) + (up ? 1 : 0);
  const whole = Math.floor(cents / 100);
  cents %= 100;
  return `${neg ? "-" : ""}${whole}.${String(cents).padStart(2, "0")}`;
}

const KIND_ABBREV: Record<string, string> = {
  function: "fn", type: "type", method: "method", interface: "iface", var: "var", const: "const",
  resource: "resource", table: "table", class: "class", selector: "selector", field: "field",
  route_handler: "route", external: "ext", file: "file", package: "pkg", service: "svc",
};

// ============================================================================
// Streaming encoders (SPEC §8)
// ============================================================================

export interface StreamWriter {
  write(chunk: string): void;
}

export interface GraphStreamOptions {
  tokenBudget?: number;
  tokensUsed?: number;
  packRoot?: string;
  session?: boolean;
  /** Emit `counts=targets:2,...,edges:3` instead of positional counts (SPEC §8.4.1). */
  labeledTrailerCounts?: boolean;
}

const groupName = (d: number) => (d === 0 ? "targets" : d === 1 ? "related" : d === 2 ? "extended" : `distance_${d}`);

/** Zero-buffering graph encoder: symbols, then edges, then `close()`. */
export class GraphStreamEncoder {
  private ids = new Map<string, number>();
  private nextId = 0;
  private group = "";
  private groupCounts = new Map<string, number>();
  private edges = 0;
  private edgesStarted = false;
  private readonly w: StreamWriter;
  private readonly opts: GraphStreamOptions;

  constructor(w: StreamWriter, tool: string, opts: GraphStreamOptions = {}) {
    this.w = w;
    this.opts = opts;
    let h = "GCF profile=graph";
    if (tool) h += ` tool=${tool}`;
    if (opts.tokenBudget) h += ` budget=${opts.tokenBudget}`;
    if (opts.tokensUsed) h += ` tokens=${opts.tokensUsed}`;
    if (opts.packRoot) h += ` pack_root=${opts.packRoot}`;
    if (opts.session) h += " session=true";
    w.write(h + "\n");
  }

  private enterGroup(distance: number): string {
    const g = groupName(distance);
    if (g !== this.group) {
      this.w.write(`## ${g}\n`);
      this.group = g;
    }
    this.groupCounts.set(g, (this.groupCounts.get(g) ?? 0) + 1);
    return g;
  }

  writeSymbol(s: GraphSymbol): void {
    this.enterGroup(s.distance ?? 0);
    const id = this.nextId++;
    this.ids.set(s.qualifiedName, id);
    this.w.write(`@${id} ${KIND_ABBREV[s.kind] ?? s.kind} ${s.qualifiedName} ${formatScore(s.score)} ${s.provenance}\n`);
  }

  /** A symbol already delivered earlier in the session (SPEC §9). */
  writeBareRef(qualifiedName: string, distance: number): void {
    this.enterGroup(distance);
    const id = this.nextId++;
    this.ids.set(qualifiedName, id);
    this.w.write(`@${id}  # previously transmitted\n`);
  }

  writeEdge(e: GraphEdge): void {
    const src = this.ids.get(e.source);
    const tgt = this.ids.get(e.target);
    if (src === undefined || tgt === undefined) return;
    if (!this.edgesStarted) {
      this.w.write("## edges [?]\n");
      this.edgesStarted = true;
    }
    const status = e.status && e.status !== "unchanged" ? ` ${e.status}` : "";
    this.w.write(`@${tgt}<@${src} ${e.edgeType}${status}\n`);
    this.edges++;
  }

  close(): void {
    const parts = [...this.groupCounts].filter(([, c]) => c > 0).map(([g, c]) => `${g}:${c}`);
    parts.push(`edges:${this.edges}`);
    const counts = this.opts.labeledTrailerCounts ? parts.join(",") : parts.map((p) => p.split(":")[1]).join(",");
    this.w.write(`##! summary symbols=${this.nextId} edges=${this.edges} counts=${counts}\n`);
  }
}

/** Zero-buffering generic encoder: `[?]` sections plus a `##! summary` trailer. */
export class GenericStreamEncoder {
  private sections: number[] = [];
  private current: { count: number } | null = null;
  private readonly w: StreamWriter;

  constructor(w: StreamWriter) {
    this.w = w;
    w.write("GCF profile=generic\n");
  }

  private checkFields(fields: string[]): void {
    for (const f of fields) {
      if (f.includes(">")) throw new GcfError("invalid_input", `streaming field name ${JSON.stringify(f)} contains '>' (a flattened path is not representable in a streaming row)`, 0);
    }
  }

  beginArray(name: string, fields: string[]): void {
    this.checkFields(fields);
    this.endArray();
    this.w.write(`## ${formatKey(name)} [?]{${fields.map(formatKey).join(",")}}\n`);
    this.current = { count: 0 };
  }

  beginKeyedMap(name: string, keyLabel: string, valueFields: string[]): void {
    this.checkFields(valueFields);
    this.endArray();
    this.w.write(`## ${formatKey(name)} [?:]{${[keyLabel, ...valueFields].map(formatKey).join(",")}}\n`);
    this.current = { count: 0 };
  }

  writeRow(values: unknown[]): void {
    if (!this.current) throw new GcfError("invalid_input", "writeRow outside beginArray/beginKeyedMap", 0);
    this.w.write(values.map(formatScalar).join("|") + "\n");
    this.current.count++;
  }

  endArray(): void {
    if (this.current) this.sections.push(this.current.count);
    this.current = null;
  }

  writeKV(key: string, value: unknown): void {
    this.endArray();
    this.w.write(`${formatKey(key)}=${formatScalar(value)}\n`);
  }

  writeInlineArray(name: string, values: unknown[]): void {
    this.endArray();
    this.w.write(`${formatKey(name)}[${values.length}]: ${values.map(formatScalar).join(",")}\n`);
  }

  close(): void {
    this.endArray();
    if (this.sections.length > 0) this.w.write(`##! summary counts=${this.sections.join(",")}\n`);
  }
}
