import { readFileSync } from "node:fs";
import { GcfCodec, toPlain } from "../src/host.ts";

const gcf = await GcfCodec.instantiate(readFileSync(new URL("../dist/gcf.wasm", import.meta.url)));

// 1. Bytes in, bytes out: no JS strings on the way. Typical in a server,
//    where the request body and the response body are already bytes.
const requestBody = new TextEncoder().encode('{"items":[{"sku":"A-1","qty":2},{"sku":"B-7","qty":1}]}');
const gcfBytes = gcf.encodeJsonBytes(requestBody);   // Uint8Array, ready to send
const jsonBytes = gcf.decodeToJsonBytes(gcfBytes);   // Uint8Array, ready to forward
console.log(gcfBytes.length, "GCF bytes ->", jsonBytes.length, "JSON bytes");
console.log(new TextDecoder().decode(gcfBytes));

// 2. Lazy decoding: values are converted only when read.
const rows = Array.from({ length: 1000 }, (_, i) => ({ id: i, name: `user ${i}`, score: i % 7 }));
const doc = gcf.decodeLazy(gcf.encode({ rows })) as { rows: { id: number; name: string; score: number }[] };
console.log(doc.rows.length, doc.rows[0].name, doc.rows[999].score); // only these values are converted
console.log(JSON.stringify(Object.keys(doc.rows[0])));
console.log(JSON.stringify(toPlain(doc.rows[1]))); // materialise a sub-tree as plain objects
