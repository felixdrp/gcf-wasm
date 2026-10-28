// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// tutorial.test.ts — docs/TUTORIAL.md must match examples/*.ts exactly, and
// every example must print the documented output under Bun and Node.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { BLOCK_RE, renderBlock, runExample } from "../scripts/tutorial";

const doc = readFileSync(join(import.meta.dir, "..", "docs/TUTORIAL.md"), "utf8");
const blocks = [...doc.matchAll(BLOCK_RE)];

describe("docs/TUTORIAL.md", () => {
  test("has examples", () => {
    expect(blocks.length).toBeGreaterThanOrEqual(7);
  });

  for (const [block, file] of blocks) {
    const documentedOutput = /Output:\n\n```text\n([\s\S]*?)\n```/.exec(block)![1];
    test(`${file}: documented code is the file, Bun output matches`, () => {
      expect(block).toBe(renderBlock(file, documentedOutput));
      expect(runExample(file, "bun").trimEnd()).toBe(documentedOutput);
    });
    test(`${file}: Node output matches`, () => {
      expect(runExample(file, "node").trimEnd()).toBe(documentedOutput);
    }, 20_000);
  }
});
