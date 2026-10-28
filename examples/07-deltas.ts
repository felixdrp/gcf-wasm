import { readFileSync } from "node:fs";
import { GcfCodec, type GenericSet } from "../src/host.ts";

const gcf = await GcfCodec.instantiate(readFileSync(new URL("../dist/gcf.wasm", import.meta.url)));

// A keyed record set: rows are identified by `key`, order does not matter.
const monday: GenericSet = {
  name: "orders", key: "id", fields: ["id", "total", "status"],
  rows: [
    { id: 1, total: 59.9, status: "shipped" },
    { id: 2, total: 20, status: "pending" },
    { id: 3, total: 12.5, status: "pending" },
  ],
};
const tuesday: GenericSet = {
  ...monday,
  rows: [
    { id: 1, total: 59.9, status: "shipped" },   // unchanged -> not sent
    { id: 2, total: 20, status: "shipped" },     // changed
    { id: 4, total: 99, status: "new" },         // added   (3 was removed)
  ],
};

// Producer: send the full set once, then only what changed.
console.log(gcf.encodeGenericFull(monday, "orders_api"));
const delta = gcf.encodeGenericDiff(monday, tuesday);
console.log(delta);

// Consumer: apply the delta to its copy; the result is verified by hash.
const newRoot = gcf.applyGenericDelta(delta, monday);
console.log(newRoot === gcf.packRoot(tuesday));
