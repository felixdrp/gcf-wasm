import { readFileSync } from "node:fs";
import { GcfCodec, GenericStreamEncoder } from "../src/host.ts";

const gcf = await GcfCodec.instantiate(readFileSync(new URL("../dist/gcf.wasm", import.meta.url)));

// Rows go out as soon as they exist: counts are deferred ([?]) and a
// trailer reports them at the end. Any writer works (stdout, a socket...).
let text = "";
const out = new GenericStreamEncoder({ write: (chunk) => (text += chunk) });
out.beginArray("events", ["ts", "level", "msg"]);
for (const [ts, level, msg] of [[1, "info", "started"], [2, "warn", "disk 91%"], [3, "info", "ok, done"]]) {
  out.writeRow([ts, level, msg]);
}
out.close();

console.log(text);
console.log(JSON.stringify(gcf.decode(text))); // trailer counts are checked on decode
