// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Thin host-side wrappers around the two WebAssembly modules (the codec and
// the structural indexer).
//
// Both modules are `wasm32-freestanding`: they import nothing (no WASI, no
// JS glue), so they are instantiated directly with `WebAssembly.instantiate`.
// Memory is the module's own single exported `Memory`; the host only copies
// bytes in and reads bytes out.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseLossless, type Json } from "./json";

const dist = join(import.meta.dir, "..", "..", "dist");

/** The codec module under test (a file in dist/): GCF_WASM=gcf_zig.wasm runs a suite against the Zig reference build. */
export const engineWasm = process.env.GCF_WASM ?? "gcf.wasm";
export const engineWasmPath = join(dist, engineWasm);
const enc = new TextEncoder();
const dec = new TextDecoder("utf-8", { fatal: true });

export type DecodeOk = { ok: true; json: string; value: Json };
export type DecodeErr = { ok: false; code: string; message: string; line: number };
export type Result = DecodeOk | DecodeErr;

interface GcfExports {
  memory: WebAssembly.Memory;
  gcf_input_alloc(len: number): number;
  gcf_decode(len: number): number;
  gcf_decode_tree(len: number): number;
  gcf_pack_root(len: number): number;
  gcf_delta_verify(len: number): number;
  gcf_delta_decode_apply(len: number): number;
  gcf_graph_delta_apply(len: number): number;
  gcf_scan_structural(len: number): number;
  gcf_scan_structural_scalar(len: number): number;
  gcf_output_ptr(): number;
  gcf_output_len(): number;
  gcf_error_name_ptr(): number;
  gcf_error_name_len(): number;
  gcf_error_message_ptr(): number;
  gcf_error_message_len(): number;
  gcf_error_line(): number;
  gcf_arena_high_water(): number;
  gcf_memory_pages(): number;
}

/** Module B: the codec, through its raw ABI. */
export class GcfEngine {
  readonly x: GcfExports;
  readonly instantiated: number;

  private constructor(x: GcfExports) {
    this.x = x;
    this.instantiated = x.memory.buffer.byteLength;
  }

  /**
   * `file`: gcf.wasm (the codec) or gcf_zig.wasm (the Zig reference build).
   * The default follows GCF_WASM, so whole suites can run against either.
   */
  static async load(file = engineWasm): Promise<GcfEngine> {
    const bytes = readFileSync(join(dist, file));
    const { instance, module } = await WebAssembly.instantiate(bytes, {});
    if (WebAssembly.Module.imports(module).length !== 0) throw new Error(`${file} must not import anything`);
    return new GcfEngine(instance.exports as unknown as GcfExports);
  }

  /** Copy `input` into the arena; returns its length. */
  load(input: string | Uint8Array): number {
    const bytes = typeof input === "string" ? enc.encode(input) : input;
    const ptr = this.x.gcf_input_alloc(bytes.length);
    if (ptr === 0 && bytes.length > 0) throw new Error("gcf_input_alloc failed (out of memory)");
    // Re-read memory.buffer after allocation: memory.grow detaches the old view.
    new Uint8Array(this.x.memory.buffer, ptr, bytes.length).set(bytes);
    return bytes.length;
  }

  private text(ptr: number, len: number): string {
    return dec.decode(new Uint8Array(this.x.memory.buffer, ptr, len));
  }

  private finish(status: number, asJson: boolean): Result {
    if (status !== 0) {
      return {
        ok: false,
        code: this.text(this.x.gcf_error_name_ptr(), this.x.gcf_error_name_len()),
        message: this.text(this.x.gcf_error_message_ptr(), this.x.gcf_error_message_len()),
        line: this.x.gcf_error_line(),
      };
    }
    const json = this.text(this.x.gcf_output_ptr(), this.x.gcf_output_len());
    return { ok: true, json, value: asJson ? parseLossless(json) : json };
  }

  decode(input: string | Uint8Array): Result {
    const len = this.load(input);
    return this.finish(this.x.gcf_decode(len), true);
  }

  packRoot(input: string): Result {
    return this.finish(this.x.gcf_pack_root(this.load(input)), false);
  }

  deltaVerify(input: string): Result {
    return this.finish(this.x.gcf_delta_verify(this.load(input)), false);
  }

  deltaDecodeApply(input: string): Result {
    return this.finish(this.x.gcf_delta_decode_apply(this.load(input)), false);
  }

  graphDeltaApply(input: string): Result {
    return this.finish(this.x.gcf_graph_delta_apply(this.load(input)), true);
  }
}

interface SimdExports {
  memory: WebAssembly.Memory;
  input_base(): number;
  ensure_capacity(bytes: number): number;
  classify_byte(b: number): number;
  count_structural(ptr: number, len: number): number;
  index_structural(ptr: number, len: number, out: number): number;
  next_structural(ptr: number, len: number, from: number): number;
}

/** Module A: the hand-written .wat structural indexer. */
export class SimdIndexer {
  readonly x: SimdExports;

  private constructor(x: SimdExports) {
    this.x = x;
  }

  /** Which build is loaded: "relaxed" (relaxed-SIMD swizzle) or "baseline". */
  variant: "relaxed" | "baseline" = "baseline";

  /**
   * Load Module A. By default the relaxed-SIMD build is used when this engine
   * validates it, otherwise the baseline SIMD128 build.
   */
  static async load(prefer: "auto" | "relaxed" | "baseline" = "auto"): Promise<SimdIndexer> {
    const relaxed = readFileSync(join(dist, "gcf_simd.relaxed.wasm"));
    const useRelaxed = prefer === "relaxed" || (prefer === "auto" && WebAssembly.validate(relaxed));
    const bytes = useRelaxed ? relaxed : readFileSync(join(dist, "gcf_simd.wasm"));
    const { instance, module } = await WebAssembly.instantiate(bytes, {});
    if (WebAssembly.Module.imports(module).length !== 0) throw new Error("gcf_simd must not import anything");
    const s = new SimdIndexer(instance.exports as unknown as SimdExports);
    s.variant = useRelaxed ? "relaxed" : "baseline";
    return s;
  }

  /** Copy bytes in, reserving room for a positions table of len + 8 entries. */
  load(bytes: Uint8Array): { ptr: number; out: number } {
    const base = this.x.input_base();
    const out = base + ((bytes.length + 15) & ~15);
    if (!this.x.ensure_capacity(out - base + (bytes.length + 8) * 4 + 16)) throw new Error("memory.grow failed");
    new Uint8Array(this.x.memory.buffer, base, bytes.length).set(bytes);
    return { ptr: base, out };
  }

  count(bytes: Uint8Array): number {
    const { ptr } = this.load(bytes);
    return this.x.count_structural(ptr, bytes.length);
  }

  positions(bytes: Uint8Array): Uint32Array {
    const { ptr, out } = this.load(bytes);
    const n = this.x.index_structural(ptr, bytes.length, out);
    return new Uint32Array(this.x.memory.buffer, out, n).slice();
  }
}

/** The structural alphabet, shared by both modules and the scalar oracle. */
export const STRUCTURAL = new Set([..."\n\"#,:=@[]^{|}~"].map((c) => c.charCodeAt(0)));

export function scalarPositions(bytes: Uint8Array): number[] {
  const out: number[] = [];
  for (let i = 0; i < bytes.length; i++) if (STRUCTURAL.has(bytes[i])) out.push(i);
  return out;
}
