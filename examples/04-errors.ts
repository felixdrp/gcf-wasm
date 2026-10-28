import { readFileSync } from "node:fs";
import { GcfCodec, GcfError } from "../src/host.ts";

const gcf = await GcfCodec.instantiate(readFileSync(new URL("../dist/gcf.wasm", import.meta.url)));

// The decoder is strict: every malformed payload is rejected with a category.
const bad = [
  "GCF profile=generic\nname=Ada\nname=Alan\n",            // duplicate key
  "GCF profile=generic\n## rows [3]{id}\n1\n2\n",          // 3 declared, 2 present
  'GCF profile=generic\nnote="unterminated\n',              // broken quote
  "hello\n",                                                // not GCF at all
];
for (const text of bad) {
  try {
    gcf.decode(text);
  } catch (e) {
    if (e instanceof GcfError) console.log(`${e.code.padEnd(18)} line ${e.line}: ${e.detail}`);
  }
}
