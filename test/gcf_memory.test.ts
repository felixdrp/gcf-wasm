// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// gcf_memory.test.ts — releasing WebAssembly memory after large payloads:
// `codec.recycle()`, the `maxRetainedMemory` option and `codec.memoryBytes`.
// WebAssembly memory cannot shrink, so the codec replaces its instance
// (between calls, never during one) and the old memory is garbage collected.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { engineWasmPath } from "./lib/engines";
import { GcfCodec, GcfError } from "../src/host";
import { init } from "../src/index";

const bytes = readFileSync(engineWasmPath);
const MiB = 1 << 20;
const rows = (n: number) => ({ users: Array.from({ length: n }, (_, i) => ({ id: i, name: `user${i}`, role: i % 3 ? "dev" : "admin", score: i / 7 })) });
const big = rows(60_000); // grows the memory to tens of MiB
const small = { a: [1, 2, 3], b: "x" };
/** Let pending promise continuations run (used where nothing should change). */
const settle = () => new Promise((r) => setTimeout(r, 20));
/** Wait until the background instance switch has happened (2 s at most). */
async function released(gcf: GcfCodec, initial: number): Promise<void> {
  for (let t = 0; t < 2000 && gcf.memoryBytes !== initial; t += 5) await new Promise((r) => setTimeout(r, 5));
  expect(gcf.memoryBytes).toBe(initial);
}

describe("memory release", () => {
  test("without a limit the memory keeps its peak (WebAssembly cannot shrink)", async () => {
    const gcf = await GcfCodec.instantiate(bytes);
    const initial = gcf.memoryBytes;
    gcf.decode(gcf.encode(big));
    const peak = gcf.memoryBytes;
    expect(peak).toBeGreaterThan(initial + 16 * MiB);
    gcf.encode(small);
    await settle();
    expect(gcf.memoryBytes).toBe(peak);
  });

  test("recycle() releases the memory; earlier results, views included, stay valid", async () => {
    const gcf = await GcfCodec.instantiate(bytes);
    const initial = gcf.memoryBytes;
    const text = gcf.encode(big);
    const view = gcf.decodeToJsonBytes(gcf.encodeJson('{"k":[1,2]}'), { view: true });
    const viewCopy = view.slice();
    expect(gcf.memoryBytes).toBeGreaterThan(initial + 16 * MiB);
    await gcf.recycle();
    expect(gcf.memoryBytes).toBe(initial);
    expect(Buffer.compare(view, viewCopy)).toBe(0); // the old memory is still referenced by the view
    expect(gcf.decode(text)).toEqual(big);
  });

  test("maxRetainedMemory: a large call is followed by a fresh instance", async () => {
    const gcf = await GcfCodec.instantiate(bytes, { maxRetainedMemory: 8 * MiB });
    const initial = gcf.memoryBytes;
    const text = gcf.encode(big);
    expect(gcf.memoryBytes).toBeGreaterThan(8 * MiB); // the switch never happens during a call
    await released(gcf, initial);
    expect(gcf.decode(text)).toEqual(big);
    await released(gcf, initial);
    expect(gcf.decode(gcf.encode(small))).toEqual(small);
  });

  test("maxRetainedMemory: a payload below the limit keeps the instance", async () => {
    const gcf = await GcfCodec.instantiate(bytes, { maxRetainedMemory: 256 * MiB });
    const x = gcf.exports;
    gcf.decode(gcf.encode(big));
    await settle();
    expect(gcf.exports).toBe(x);
  });

  test("many large calls in one synchronous run stay correct while a switch is pending", async () => {
    const gcf = await GcfCodec.instantiate(bytes, { maxRetainedMemory: 4 * MiB });
    const want = gcf.encode(big);
    for (let i = 0; i < 4; i++) {
      expect(gcf.encode(big)).toBe(want);
      expect(gcf.decode(want)).toEqual(big);
    }
    await settle();
    expect(gcf.encode(big)).toBe(want);
  });

  test("errors still report, and still release a large instance", async () => {
    const gcf = await GcfCodec.instantiate(bytes, { maxRetainedMemory: 8 * MiB });
    const initial = gcf.memoryBytes;
    const text = gcf.encode(big);
    await released(gcf, initial);
    expect(() => gcf.decode(text.replace("## users [60000]", "## users [60001]"))).toThrow(GcfError);
    await released(gcf, initial);
  });

  test("init(source, options) passes the options; each call returns a new codec", async () => {
    const a = await init(bytes, { maxRetainedMemory: 8 * MiB });
    const b = await init(new WebAssembly.Module(bytes), { maxRetainedMemory: 8 * MiB });
    expect(a).not.toBe(b);
    const initial = a.memoryBytes;
    a.encode(big);
    await released(a, initial);
  });
});
