// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// cli.ts — the `gcf` command line, shared by bin/gcf.ts (repository) and
// the npm package's bin.
//
//   gcf encode [file] [--graph] [--no-flatten]   JSON -> GCF (stdin if no file)
//   gcf decode [file] [--large-int=MODE]         GCF  -> JSON (pretty-printed)
//   gcf stats  [file] [--graph]                  JSON vs GCF size (estimated tokens)
import { readFileSync } from "node:fs";
import { type GcfCodec, GcfError, type LargeIntMode } from "./host.ts";

const USAGE = `usage:
  gcf encode [file] [--graph] [--no-flatten]   JSON -> GCF (stdin if no file)
  gcf decode [file] [--large-int=error|string|bigint|number]
  gcf stats  [file] [--graph]                  JSON vs GCF size and estimated tokens`;

/** Run the CLI; returns the process exit code. */
export function main(argv: string[], gcf: GcfCodec): number {
  const [command, ...rest] = argv;
  if (command === "--help" || command === "-h") {
    console.log(USAGE);
    return 0;
  }
  if (command !== "encode" && command !== "decode" && command !== "stats") {
    console.error(USAGE);
    return command ? 1 : 0;
  }
  const flags = new Set(rest.filter((a) => a.startsWith("--")));
  const file = rest.find((a) => !a.startsWith("--"));
  const input = readFileSync(file && file !== "-" ? file : 0, "utf8");

  /** A graph payload has a `symbols` array; everything else is generic data. */
  const isGraphPayload = (json: string): boolean => {
    if (flags.has("--graph")) return true;
    try {
      const v = JSON.parse(json);
      return v !== null && typeof v === "object" && Array.isArray(v.symbols) && Array.isArray(v.edges ?? []);
    } catch {
      return false;
    }
  };
  const encode = (json: string): string =>
    isGraphPayload(json) ? gcf.encodeGraph(JSON.parse(json)) : gcf.encodeJson(json, { noFlatten: flags.has("--no-flatten") });

  try {
    if (command === "encode") {
      process.stdout.write(encode(input));
    } else if (command === "decode") {
      const mode = [...flags].find((f) => f.startsWith("--large-int="))?.split("=")[1] as LargeIntMode | undefined;
      const value = gcf.decode(input, { largeInt: mode ?? "string" });
      console.log(JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
    } else {
      const out = encode(input);
      // Estimate: ~4 characters per token (the heuristic the reference CLI
      // uses). Real counts depend on the model's tokenizer.
      const jsonTokens = Math.round(input.trim().length / 4);
      const gcfTokens = Math.round(out.trim().length / 4);
      const bar = (n: number) => "█".repeat(Math.max(1, Math.round((30 * n) / Math.max(jsonTokens, 1)))).padEnd(30, "░");
      console.log(`JSON  ${bar(jsonTokens)}  ${input.length} chars  ~${jsonTokens} tokens`);
      console.log(`GCF   ${bar(gcfTokens)}  ${out.length} chars  ~${gcfTokens} tokens`);
      console.log(`\n~${Math.round(100 * (1 - gcfTokens / Math.max(jsonTokens, 1)))}% fewer tokens (estimate: 4 chars/token)`);
    }
    return 0;
  } catch (e) {
    if (e instanceof GcfError) {
      console.error(`gcf: ${e.message}`);
      return 2;
    }
    throw e;
  }
}
