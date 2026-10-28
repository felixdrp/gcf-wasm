> Original project brief (kept for reference). The public project README is [`../README.md`](../README.md).

# Role & Objective
You are a Principal Systems Engineer specializing in WebAssembly (WASM), Zig, and high-performance zero-dependency binary serialization protocols. 
Your task is to implement a production-ready, highly optimized WebAssembly (WASM) implementation of the Graph Compact Format (GCF) specification by Blackwell Systems. 

The project must accomplish **both** of the following core engineering goals:
1. **Maximize SIMD Performance Benchmarks:** Implement 128-bit vectorization for blazing-fast string tokenization.
2. **Build a Complete Graph Parsing Engine:** Fully implement the hierarchical, nested data structures of the GCF specification (handling nested nodes, attributes, edges, keyed-maps, and delta sessions) while maintaining a strict zero-allocation or arena-allocated runtime model.

# Context: What is GCF?
Graph Compact Format (GCF) is an AI-native wire format designed by Blackwell Systems to minimize token footprint during LLM interactions. It is a highly compressed, zero-dependency alternative to JSON that encodes strict graph structures. Elements are tightly bound by structural tokens, meaning any parser must spend significant CPU cycles scanning for structural delimiters (like `:`, `,`, `{`, `}`, `[`, `]`).

# Detailed Requirements & Architecture

### 1. High-Performance SIMD Vectorization
* **Parallel Tokenization:** Scan buffers 16 bytes at a time using WASM SIMD 128-bit registers (e.g., `v128`, `i8x16.eq`, `i8x16.bitmask`).
* **Branchless Offsets:** Use trailing zero counts (`i32.ctz` or `@ctz`) on resulting bitmasks to immediately deduce structural token character positions without looping through individual bytes.
* **Fallback Mechanics:** Ensure clean handling for buffer remainders that are smaller than 16 bytes (tail processing).

### 2. Complete Graph & Hierarchical Parsing Engine
* **Nested Structures:** Implement full structural decoding for GCF primitives:
  * **Nodes & Attributes:** Correctly parse entity keys, numerical/string attributes, and property pairings (`key:value`).
  * **Edges & Adjacency:** Map references between entities inside the graph structure.
  * **Keyed-Maps & Delta Sessions:** Handle `keyed-map` contexts and sequential deduplication layers (`generic-delta-session`).
* **Memory Architecture:** Maintain O(1) space complexity or predictable linear heap management. Use a single deterministic WebAssembly `Memory` instance. In the Zig tier, use a dedicated, ultra-fast `ArenaAllocator` or static ring buffers to completely eliminate standard heap fragmentation and pointer-chasing overhead.

### 3. Deliverable Modules Required
* **Module A (Native .wat Code):** A low-level, pure WebAssembly Text Format (`.wat`) implementation showcasing explicit stack operations and SIMD `bitmask` filtering for structural GCF separators. It must feature meticulous line-by-line pedagogical comments.
* **Module B (Zig Core Architecture):** A clean `gcf.zig` package achieving the complete graph-parsing engine objectives. It must compile targeting `-target wasm32-freestanding -O ReleaseFast -fsimd`, demonstrating native `@Vector(16, u8)` syntax and robust recursive/iterative parsing models for deeply nested structures.
* **Module C (Bun Test Harness & Fixture Compliance):** A test automation script (`gcf_compliance.test.ts`) using `bun:test` and `node:wasi` to parse official Blackwell Systems test fixtures (including `generic-profile-conformance` and `errors-v2`). It should evaluate and assert full spec adherence while outputting performance metrics.

---

# Configurable Future Execution Options

When requested by the user, you must inject the following strict configurations into the architecture:

### [FUTURE_OPTION] A. Target Performance Thresholds
When this option is activated, write benchmarking scripts inside the Bun test harness to measure and assert the following metrics:
* **Throughput:** Target a minimum parsing speed of **1.5 GB/s** on standard x86_64 or ARM64 host hardware.
* **Latency:** Tokenize structural elements with a maximum budget of **3 CPU cycles per 16-byte block**.
* **Jitter Control:** Ensure execution variance remains below **2%** across 10,000 continuous iterations of the Blackwell compliance suite.

### [FUTURE_OPTION] B. Constrained Edge Memory Limits
When this option is activated, refactor the WASM and Zig memory engines to comply with ultra-constrained environments (e.g., Cloudflare Workers, IoT Gateways):
* **Hard Page Cap:** Limit the WebAssembly instance to a maximum of **4 memory pages (256 KB)** total allocation space.
* **Static Allocation:** Replace the `ArenaAllocator` with a zero-alloc, zero-copy pointer window that processes strings directly over the incoming network buffer.
* **Stack Guardrails:** Explicitly avoid deep recursion in the graph nesting parser by implementing a manual, loop-bound stack array limited to a **maximum depth of 16 layers**.

> **Implementation plan:** see [`docs/OPTION_B_PLAN.md`](OPTION_B_PLAN.md). It covers the architecture, the 256 KB memory budget and the steps. Decided: the manual stack holds **32 layers** instead of 16, because the GCF spec (§12) requires decoders to support at least 32 levels of nesting.

---

# Output Expectations
Generate fully fleshed-out code files for the `.wat` module, the `.zig` optimization engine, and the Bun Test harness. Do not truncate the code, shortcut recursive logic, or use arbitrary `// TODO` placeholders for the data-parsing layers. Provide complete implementation details and comprehensive documentation for every architectural layer.

---

# Project documentation

This brief started the project. Its `.zig` engine now lives in
[gcf-zig](https://codeberg.org/felixdrp/gcf-zig), the reference
implementation; this repository holds the `.wat` modules, the Bun harness
and the benchmarks.

* [`docs/TUTORIAL.md`](TUTORIAL.md): how to use the codec (encode, decode, graphs, streaming, deltas, CLI), with runnable examples.
* [`docs/ARCHITECTURE.md`](ARCHITECTURE.md): how it is built (modules, SIMD indexer, conformance, FUTURE_OPTION A results); the engine's memory model and encoder are in gcf-zig's `docs/ARCHITECTURE.md`.
* [`docs/OPTION_B_PLAN.md`](OPTION_B_PLAN.md): implementation plan for FUTURE_OPTION B.
* [`docs/JS_WASM_BOUNDARY.md`](JS_WASM_BOUNDARY.md): study of the JS ⇄ wasm data-transfer cost (measurements, techniques, standards outlook, sources).
* [`bench/README.md`](../bench/README.md): benchmark against the Blackwell TypeScript SDK.
