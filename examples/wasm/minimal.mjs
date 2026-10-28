// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Minimal host for dist/gcf.wasm using only the raw WebAssembly ABI
// (docs/WASM_ABI.md) — no JS wrapper. The same steps apply in any runtime.
//   node examples/wasm/minimal.mjs   |   bun examples/wasm/minimal.mjs
import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(new URL("../../dist/gcf.wasm", import.meta.url)), {});
const x = instance.exports;
const utf8 = new TextEncoder();
const text = new TextDecoder();

if (x.gcf_abi_version() !== 1) throw new Error("unsupported gcf.wasm ABI");

function call(fn, input, ...args) {
  const bytes = utf8.encode(input);
  const ptr = x.gcf_input_alloc(bytes.length);                  // 1. reserve input
  new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes); // 2. copy it in
  const status = fn(bytes.length, ...args);                      // 3. run
  const read = (p, n) => text.decode(new Uint8Array(x.memory.buffer, p, n)); // re-read buffer: memory may grow
  if (status !== 0) {                                            // 4a. error
    return { error: read(x.gcf_error_name_ptr(), x.gcf_error_name_len()), code: status, line: x.gcf_error_line(), message: read(x.gcf_error_message_ptr(), x.gcf_error_message_len()) };
  }
  return { output: read(x.gcf_output_ptr(), x.gcf_output_len()) }; // 4b. result
}

console.log(call(x.gcf_encode, '{"users":[{"id":1,"name":"Ada"},{"id":2,"name":"Linus"}]}', 0).output);
console.log(call(x.gcf_decode, "GCF profile=generic\n## users [2]{id,name}\n1|Ada\n2|Linus\n").output);
console.log(call(x.gcf_decode, "GCF profile=generic\n## rows [3]{id}\n1\n2\n"));
