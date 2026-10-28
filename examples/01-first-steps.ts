import { readFileSync } from "node:fs";
import { GcfCodec } from "../src/host.ts";

// One instance per process: it owns its WebAssembly memory and can be reused.
const gcf = await GcfCodec.instantiate(readFileSync(new URL("../dist/gcf.wasm", import.meta.url)));

const data = {
  service: "billing",
  users: [
    { id: 1, name: "Ada Lovelace", role: "admin" },
    { id: 2, name: "Alan Turing", role: "dev" },
  ],
};

const text = gcf.encode(data);
console.log(text);

const back = gcf.decode(text);
console.log(JSON.stringify(back) === JSON.stringify(data)); // lossless round trip
