import { readFileSync } from "node:fs";
import { GcfCodec } from "../src/host.ts";

const gcf = await GcfCodec.instantiate(readFileSync(new URL("../dist/gcf.wasm", import.meta.url)));

// The encoder picks the most compact canonical form for every value.
console.log(gcf.encode({
  config: { region: "eu-west", retries: 3 },          // nested object -> section
  tags: ["prod", "api", "v2"],                       // primitives -> inline array
  servers: {                                         // object of objects -> keyed table
    "web-1": { cpu: 23, status: "ok" },
    "db-1": { cpu: 71, status: "warn" },
  },
  orders: [                                          // objects -> tabular rows
    { id: "A1", customer: { name: "Ada", tier: "gold" }, items: ["pen"], currency: "EUR" },
    { id: "A2", customer: { name: "Alan", tier: "basic" }, items: [], currency: "EUR" },
  ],
  mixed: [1, "two", { three: 3 }],                   // mixed array -> expanded items
}));
