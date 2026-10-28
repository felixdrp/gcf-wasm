// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Fill (or check) the example blocks of docs/TUTORIAL.md from examples/*.ts.
//
//   bun scripts/tutorial.ts          rewrite the blocks from the files + their output
//   bun scripts/tutorial.ts --check  exit 1 if the document is out of date
//
// A block is everything between `<!-- example: <path> -->` and
// `<!-- /example -->`: the file's code, then the output of running it.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const docPath = join(root, "docs/TUTORIAL.md");

export function runExample(file: string, runtime: "bun" | "node" = "bun"): string {
  const cmd = runtime === "bun" ? ["bun", file] : ["node", "--experimental-strip-types", "--no-warnings", file];
  const r = Bun.spawnSync(cmd, { cwd: root, stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`${file} failed under ${runtime}:\n${r.stderr.toString()}`);
  return r.stdout.toString();
}

export function renderBlock(file: string, output: string): string {
  const code = readFileSync(join(root, file), "utf8").trimEnd();
  return `<!-- example: ${file} -->\n\`\`\`ts\n${code}\n\`\`\`\n\nOutput:\n\n\`\`\`text\n${output.trimEnd()}\n\`\`\`\n<!-- /example -->`;
}

export const BLOCK_RE = /<!-- example: (\S+) -->[\s\S]*?<!-- \/example -->/g;

if (import.meta.main) {
  const doc = readFileSync(docPath, "utf8");
  const updated = doc.replace(BLOCK_RE, (_m, file: string) => renderBlock(file, runExample(file)));
  if (process.argv.includes("--check")) {
    if (updated !== doc) {
      console.error("docs/TUTORIAL.md is out of date: run `bun scripts/tutorial.ts`");
      process.exit(1);
    }
    console.log("docs/TUTORIAL.md is up to date");
  } else {
    writeFileSync(docPath, updated);
    console.log("docs/TUTORIAL.md updated");
  }
}
