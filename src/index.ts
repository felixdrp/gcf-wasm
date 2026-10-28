// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// index.ts — entry point of the npm package (@felixdrp/gcf-wasm).
//
//   import { init } from "@felixdrp/gcf-wasm";
//   const gcf = await init();                  // loads gcf.wasm next to this module
//   gcf.decode(gcf.encode({ hello: "world" }));
//
// Works in Node, Bun and Deno (the wasm is read from disk) and in browsers,
// bundlers and edge runtimes (it is fetched; bundlers recognise the
// `new URL("./gcf.wasm", import.meta.url)` asset pattern). Pass your own
// bytes, URL, Response or WebAssembly.Module to control loading.
export * from "./host.ts";
import { GcfCodec } from "./host.ts";

export type WasmSource = BufferSource | WebAssembly.Module | URL | string | Response | Promise<Response>;

let shared: Promise<GcfCodec> | undefined;

async function wasmBytes(source: URL | string | Response | Promise<Response>): Promise<BufferSource> {
  if (source instanceof URL || typeof source === "string") {
    const url = source instanceof URL ? source : new URL(source, import.meta.url);
    if (url.protocol === "file:") {
      const { readFile } = await import("node:fs/promises");
      return readFile(url);
    }
    source = fetch(url);
  }
  const res = await source;
  if (!res.ok) throw new Error(`failed to load gcf.wasm: HTTP ${res.status}`);
  return res.arrayBuffer();
}

/**
 * Create a codec. Without arguments, returns a shared instance backed by the
 * `gcf.wasm` shipped with this package (loaded once). Each codec owns its
 * own WebAssembly memory; create more than one only for parallel use.
 */
export function init(source?: WasmSource): Promise<GcfCodec> {
  if (source === undefined) {
    shared ??= wasmBytes(new URL("./gcf.wasm", import.meta.url)).then((b) => GcfCodec.instantiate(b));
    return shared;
  }
  if (source instanceof WebAssembly.Module || source instanceof ArrayBuffer || ArrayBuffer.isView(source)) {
    return GcfCodec.instantiate(source as BufferSource | WebAssembly.Module);
  }
  return wasmBytes(source as URL | string | Response).then((b) => GcfCodec.instantiate(b));
}
