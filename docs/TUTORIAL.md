# GCF codec tutorial

This tutorial shows how to use the codec from JavaScript or TypeScript:
encode data to GCF, decode it back, and use graphs, streaming and deltas.
Every example is a runnable file in [`examples/`](../examples). The output
shown under each one is its real output: `test/tutorial.test.ts` runs every
example under Bun and Node and fails if the code or output here drifts from
the files.

What you get:

* **Decode and encode** both GCF profiles: generic data and code graphs.
* **Canonical output.** The encoder is byte-for-byte identical to the
  reference Blackwell encoder: it is checked against all 323 official
  conformance fixtures and against 120,000 generated values.
* **Strict decoding.** Every malformed payload is rejected with a precise
  error category.
* **Exact 64-bit integers**, with an explicit policy for JavaScript's 2^53
  limit.

## 0. Setup

You need [Bun](https://bun.sh). The codec is written in WebAssembly text,
so building it needs no other compiler.

```sh
bun install       # wabt (only used to compile the .wat modules)
bun run build     # produces dist/gcf.wasm
```

The API lives in [`src/host.ts`](../src/host.ts) and needs no compilation:
Bun imports it directly, and Node 22.6+ does too with
`--experimental-strip-types`. In a browser, fetch the module and pass the
bytes:

```ts
const gcf = await GcfCodec.instantiate(await (await fetch("/gcf.wasm")).arrayBuffer());
```

## 1. First steps

`encode` turns any JSON value into GCF text; `decode` turns it back.

<!-- example: examples/01-first-steps.ts -->
```ts
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
```

Output:

```text
GCF profile=generic
service=billing
## users [2]{id,name,role}
1|Ada Lovelace|admin
2|Alan Turing|dev

true
```
<!-- /example -->

Reading the output:

* `GCF profile=generic` is the header every payload starts with.
* `service=billing` is a plain `key=value` line.
* `## users [2]{id,name,role}` is a table header: the field names appear
  once, followed by one `|`-separated row per object. The `[2]` is a count
  the decoder verifies.

## 2. What the encoder chooses

You never pick a layout; the encoder chooses the canonical one for each
value.

<!-- example: examples/02-shapes.ts -->
```ts
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
```

Output:

```text
GCF profile=generic
## config
  region=eu-west
  retries=3
tags[3]: prod,api,v2
## servers [2:]{key,cpu,status}
web-1|23|ok
db-1|71|warn
## orders [2]{id,"customer>name","customer>tier",items,currency=EUR}
@0 A1|Ada|gold|^
.items [1]: pen
@1 A2|Alan|basic|^
.items [0]
## mixed [3]
@0 =1
@1 =two
@2 {}
  three=3
```
<!-- /example -->

* **Nested object** → a `## section` with indented members.
* **Array of primitives** → an inline `name[N]: a,b,c`.
* **Object whose values are objects** → a *keyed table* `[N:]`: the first
  column is the member key.
* **Array of objects** → a table. Inside it:
  * `customer` was the same small object shape in every row, so it is
    *flattened* into `customer>name` / `customer>tier` columns;
  * `currency` was identical in every row, so it is declared once as a
    *constant column*, `currency=EUR`;
  * `items` is an array, so each row points to it with `^` and attaches it
    below as `.items ...`. Such rows carry an `@index` prefix.
* **Mixed array** → *expanded* items, `@0 =1`, `@1 =two`, `@2 {}`.

Pass `{ noFlatten: true }` to `encode` to keep nested objects as attachments
instead of `a>b` columns.

## 3. Key order and numbers

Two JavaScript details matter for exact round trips.

<!-- example: examples/03-numbers-and-keys.ts -->
```ts
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
```

Output:

```text
"10"=2 b=1 a=3
b=1 "10"=2 a=3
id=9007199254740993 count=7
unsafe_integer: integer 9007199254740993 exceeds the safe-in...
{"id":"9007199254740993","count":7}
bigint true
{"id":9007199254740993,"count":7}
```
<!-- /example -->

* **Key order.** JS objects move integer-like keys (`"10"`) to the front.
  When order matters, encode the JSON text itself with `encodeJson`.
* **Big integers.** GCF integers are exact 64-bit values, but a JS `number`
  is exact only up to 2^53. Encode a `bigint` to send exact digits. On
  decode, `decode` refuses to round silently (`unsafe_integer`) unless you
  pick a policy: `largeInt: "string" | "bigint" | "number"`. `decodeToJson`
  returns JSON text with the exact digits.
* **Ordinary numbers** are written in canonical form: `75.0` → `75`,
  `1e-7` → `1e-7`, `-0` → `0`, and a double ≥ 2^53 uses exponent form.

## 4. Errors

The decoder is strict (SPEC §16.5): there is no lenient mode. Every failure
is a `GcfError` with a `code` (the spec's category), a `line` and a
human-readable `detail`.

<!-- example: examples/04-errors.ts -->
```ts
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
```

Output:

```text
duplicate_key      line 3: duplicate key
count_mismatch     line 2: declared count does not match the number of items
unterminated_quote line 2: unterminated quoted string
missing_header     line 1: payload must begin with a 'GCF profile=...' header line
```
<!-- /example -->

The encoder throws `GcfError` too: `out_of_range` for integers beyond int64,
`duplicate_key` for repeated keys in JSON text, and `invalid_input` for data
a given encoding cannot represent.

## 5. Graph payloads and sessions

The graph profile is specialised for code-intelligence results: symbols with
a kind, score, provenance and distance, and edges between them.

<!-- example: examples/05-graphs.ts -->
```ts
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
```

Output:

```text
GCF profile=graph tool=context_for_task symbols=2 edges=1
## targets
@0 fn pkg.Auth 0.78 lsp
## related
@1 fn pkg.Server 0.54 lsp
## edges [1]
@0<@1 calls

{"source":"pkg.Server","target":"pkg.Auth","edgeType":"calls","status":""}
GCF profile=graph tool=context_for_task symbols=2 edges=1 session=true
## targets
@1  # previously transmitted
@2 method pkg.Handler 0.60 ast
## edges [1]
@1<@2 calls
```
<!-- /example -->

* `encodeGraph` groups symbols by distance (`targets`, `related`,
  `extended`, `distance_N`), orders them by score, assigns IDs, and writes
  edges as `@target<@source type`.
* `decode` returns `{tool, tokenBudget, tokensUsed, packRoot, symbols,
  edges}` with full kind names.
* `GraphSession` remembers what was already sent in a conversation: known
  symbols become `@id  # previously transmitted`, and IDs stay stable across
  calls.

## 6. Streaming

When rows arrive over time (a database cursor, a paginated API), stream
them instead of buffering. `[?]` defers the count, and a `##! summary`
trailer reports it at the end.

The streaming encoders run in JavaScript, not in `gcf.wasm`: they write
each row as it arrives, and a call into wasm per row would cost more than
it saves. They follow the same quoting and number rules as the module (the
tests check that the two agree), so they need no `GcfCodec`.

<!-- example: examples/06-streaming.ts -->
```ts
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
```

Output:

```text
GCF profile=generic
## events [?]{ts,level,msg}
1|info|started
2|warn|disk 91%
3|info|"ok, done"
##! summary counts=3

{"events":[{"ts":1,"level":"info","msg":"started"},{"ts":2,"level":"warn","msg":"disk 91%"},{"ts":3,"level":"info","msg":"ok, done"}]}
```
<!-- /example -->

`GenericStreamEncoder` also has `beginKeyedMap`, `writeKV` and
`writeInlineArray`. For graphs, `GraphStreamEncoder` takes `writeSymbol`,
`writeBareRef` and `writeEdge`, then `close()`; pass
`{ labeledTrailerCounts: true }` for `counts=targets:2,...` in the trailer.

## 7. Keyed sets and deltas

For data that changes turn after turn, send the full set once and then only
the differences. A `GenericSet` names the identity field (`key`); row order
does not matter.

<!-- example: examples/07-deltas.ts -->
```ts
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
```

Output:

```text
GCF profile=generic tool=orders_api pack_root=sha256:c1f90e19adc6d95e8190df0e2003f8b91aa507843f87c6d0db97f7620ffd9b60 key=id
## orders [3]{@id,total,status}
1|59.9|shipped
2|20|pending
3|12.5|pending

GCF profile=generic delta=true base_root=sha256:c1f90e19adc6d95e8190df0e2003f8b91aa507843f87c6d0db97f7620ffd9b60 new_root=sha256:2dfb221aab80033410804b92ab7423a6e203842b72a5a44be9120b1b78fb085d key=id
## added [1]{@id,total,status}
4|99|new
## changed [1]{@id,total,status}
2|20|shipped
## removed [1]{@id}
3

true
```
<!-- /example -->

* `encodeGenericFull` emits the set with `pack_root` (a SHA-256 of the
  logical set) and `key=` in the header.
* `encodeGenericDiff` emits only `added`, `changed` and `removed` rows,
  sorted by identity. A schema change throws: send a full payload instead.
* `applyGenericDelta` checks `base_root`, rejects contradictory operations,
  applies the delta, and verifies the result against `new_root`. It returns
  the new root.
* `GenericDeltaSession` automates the producer side: deltas each turn and a
  full payload every N turns (`{ mode: "fixedN", n }`) or whenever
  accumulated deltas would outgrow a full payload (`{ mode: "sizeGuard" }`).
* Graphs work the same way with `encodeGraphDelta`, `applyGraphDelta` and
  `packRoot({symbols, edges})`.

## 8. Bytes and lazy decoding

Two ways to spend less time crossing between JavaScript and WebAssembly
(the study behind them is in [`JS_WASM_BOUNDARY.md`](JS_WASM_BOUNDARY.md)).

<!-- example: examples/08-bytes-and-lazy.ts -->
```ts
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
```

Output:

```text
54 GCF bytes -> 55 JSON bytes
GCF profile=generic
## items [2]{sku,qty}
A-1|2
B-7|1

1000 user 0 5
["id","name","score"]
{"id":1,"name":"user 1","score":1}
```
<!-- /example -->

* `encodeJsonBytes` / `decodeToJsonBytes` take and return `Uint8Array`, with
  no `TextEncoder`, `TextDecoder`, `JSON.parse` or `JSON.stringify` in
  between. In a server pipeline this is 2.0–5.0× faster than the TypeScript
  SDK for encoding and 3.9–13.8× faster for decoding. Pass `{ view: true }` for
  a zero-copy view into wasm memory, valid only until the next call.
  `encodeJsonBytes(bytes, { profile: "graph" })` encodes graph payloads.
* `decodeLazy` returns objects and arrays that behave like plain ones but
  convert values only when read. The document is still decoded in full
  inside the engine, so the gain comes from what you skip reading: reading
  one row of a large table is ~1.8× faster than `decode`, but reading every
  row is about the same. `toPlain` turns a lazy value or sub-tree into plain
  objects. Prefer `decode` for graphs: its columnar transfer is already
  faster.

## 9. Command line

```sh
bun bin/gcf.ts encode data.json            # JSON -> GCF (graph payloads detected)
bun bin/gcf.ts decode data.gcf             # GCF -> pretty JSON
bun bin/gcf.ts stats data.json             # size comparison (estimated tokens)
```

With Node: `node --experimental-strip-types bin/gcf.ts ...`.

## 10. API reference

| `GcfCodec` method | Purpose |
|---|---|
| `GcfCodec.instantiate(bytes)` | Load `dist/gcf.wasm` |
| `decode(text, { largeInt })` | GCF → JS value (either profile) |
| `decodeToJson(text)` | GCF → JSON text (exact integers) |
| `decodeToJsonBytes(bytes, { view })` | GCF bytes → JSON bytes |
| `decodeLazy(text, { largeInt })` | GCF → lazily converted objects (`toPlain` to materialise) |
| `encode(value, { noFlatten })` | JS value → generic GCF |
| `encodeJson(jsonText, { noFlatten })` | JSON text → generic GCF (exact key order) |
| `encodeJsonBytes(bytes, { profile, noFlatten, view })` | JSON bytes → GCF bytes |
| `encodeGraph(payload)` | Graph payload → GCF |
| `encodeGraphDelta(delta)` / `applyGraphDelta(wire, base)` | Graph deltas |
| `encodeGenericFull(set, tool)` | Keyed set with `pack_root` and `key` |
| `encodeGenericDiff(base, next)` / `encodeGenericDelta(delta)` | Generic deltas |
| `applyGenericDelta(wire, base)` | Verify and apply a delta; returns the new root |
| `packRoot(graphOrSet)` | `gcf-pack-root-v1` hash |
| `encodeGrouped(rows, keyField, groupField)` | Opt-in value grouping (SPEC §7.4.8) |

Classes: `GraphSession`, `GenericDeltaSession`, `GraphStreamEncoder`,
`GenericStreamEncoder`, `GcfError`. Helpers: `toPlain`, `formatScalar`,
`formatKey`, `needsQuote`, `quoteString`, `formatNumber`, `formatScore`.

## 11. Performance tips

* **Create one `GcfCodec`** and reuse it. Each call resets its memory arena
  in O(1).
* **Data already in bytes** (an HTTP body, a file, a socket)? Use
  `encodeJsonBytes` / `decodeToJsonBytes`: no JS strings at all.
* **Already have JSON text?** Use `encodeJson`: it skips `JSON.stringify`.
* **Reading only part of a large document?** Use `decodeLazy`.
* **Forwarding the result as JSON?** Use `decodeToJson`: it skips
  `JSON.parse`.
* **Graph payloads** are decoded through a compact columnar transfer
  automatically.

Measured against the Blackwell TypeScript SDK (see
[`bench/README.md`](../bench/README.md)):

* **Decoding:** 1.6–4.5× faster.
* **Encoding:** 1.5–3.0× faster from JSON text, and 1.1–2.2× from JS values
  on every payload. Graphs are written straight into wasm memory; generic
  values still cross as `JSON.stringify` text.
