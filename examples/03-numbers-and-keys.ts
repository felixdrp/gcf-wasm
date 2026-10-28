import { readFileSync } from "node:fs";
import { GcfCodec } from "../src/host.ts";

const gcf = await GcfCodec.instantiate(readFileSync(new URL("../dist/gcf.wasm", import.meta.url)));

// 1. Key order. JS objects move integer-like keys first; JSON text does not.
const json = '{"b":1,"10":2,"a":3}';
console.log(gcf.encode(JSON.parse(json)).trim().split("\n").slice(1).join(" "));
console.log(gcf.encodeJson(json).trim().split("\n").slice(1).join(" "));

// 2. Exact 64-bit integers: pass a bigint in, choose a policy on the way out.
const text = gcf.encode({ id: 9007199254740993n, count: 7 });
console.log(text.trim().split("\n").slice(1).join(" "));
try {
  gcf.decode(text); // default policy: refuse to lose precision silently
} catch (e) {
  console.log((e as Error).message.slice(0, 60) + "...");
}
console.log(JSON.stringify(gcf.decode(text, { largeInt: "string" })));
const exact = gcf.decode(text, { largeInt: "bigint" }) as { id: bigint };
console.log(typeof exact.id, exact.id === 9007199254740993n);
console.log(gcf.decodeToJson(text)); // JSON text keeps the exact digits
