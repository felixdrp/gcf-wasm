import { readFileSync } from "node:fs";
import { GcfCodec, GraphSession, type GraphPayload } from "../src/host.ts";

const gcf = await GcfCodec.instantiate(readFileSync(new URL("../dist/gcf.wasm", import.meta.url)));

const payload: GraphPayload = {
  tool: "context_for_task",
  symbols: [
    { qualifiedName: "pkg.Server", kind: "function", score: 0.54, provenance: "lsp", distance: 1 },
    { qualifiedName: "pkg.Auth", kind: "function", score: 0.78, provenance: "lsp", distance: 0 },
  ],
  edges: [{ source: "pkg.Server", target: "pkg.Auth", edgeType: "calls" }],
};

const text = gcf.encodeGraph(payload); // grouped by distance, IDs, edges by ID
console.log(text);
const decoded = gcf.decode(text) as GraphPayload;
console.log(JSON.stringify(decoded.edges[0]));

// Sessions: symbols sent before become bare references with stable IDs.
const session = new GraphSession(gcf);
session.encode(payload);
console.log(session.encode({
  tool: "context_for_task",
  symbols: [
    payload.symbols[1],
    { qualifiedName: "pkg.Handler", kind: "method", score: 0.6, provenance: "ast", distance: 0 },
  ],
  edges: [{ source: "pkg.Handler", target: "pkg.Auth", edgeType: "calls" }],
}));
