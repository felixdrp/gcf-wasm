// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Build the npm package in npm/: bundles the JS API and CLI, emits type
// declarations, copies the codec module, LICENSE and NOTICE.
//   bun scripts/build-npm.ts            (expects dist/gcf.wasm: run `bun run build` first)
//
// The package ships the codec as npm/dist/gcf.wasm, in its release form
// without debug names (dist/gcf.wasm, built from src/wat/*.wat).
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const out = join(root, "npm/dist");
const codec = join(root, "dist/gcf.wasm");
if (!existsSync(codec)) throw new Error("dist/gcf.wasm missing: run `bun run build` first");
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

// 1. JS: one ESM file for the library, one for the CLI. Platform-neutral:
//    node:fs is only imported dynamically for file: URLs, so it stays external.
for (const [entry, name] of [["src/index.ts", "index.js"], ["src/cli-npm.ts", "cli.js"]] as const) {
  const r = await Bun.build({ entrypoints: [join(root, entry)], target: "browser", format: "esm", external: ["node:*"], minify: false });
  if (!r.success) throw new AggregateError(r.logs, `bundling ${entry} failed`);
  let code = await r.outputs[0].text();
  if (name === "cli.js") code = "#!/usr/bin/env node\n" + code.replace(/^#!.*\n/, "");
  writeFileSync(join(out, name), code);
}

// 2. Types: tsc declarations, with .ts import specifiers rewritten to .js.
const types = join(root, "npm/.types");
rmSync(types, { recursive: true, force: true });
const tsc = Bun.spawnSync(
  [join(root, "node_modules/.bin/tsc"), "src/index.ts", "--declaration", "--emitDeclarationOnly", "--allowImportingTsExtensions", "--target", "es2022", "--module", "esnext", "--moduleResolution", "bundler", "--lib", "es2022,dom", "--skipLibCheck", "--types", "node", "--outDir", types],
  { cwd: root, stdout: "inherit", stderr: "inherit" },
);
if (tsc.exitCode !== 0) throw new Error("tsc failed");
for (const f of readdirSync(types)) {
  writeFileSync(join(out, f), readFileSync(join(types, f), "utf8").replace(/(from\s+["']\.\/[^"']+)\.ts(["'])/g, "$1.js$2"));
}
rmSync(types, { recursive: true, force: true });

// 3. Assets and legal files.
cpSync(codec, join(out, "gcf.wasm"));
for (const f of ["LICENSE", "NOTICE"]) cpSync(join(root, f), join(root, "npm", f));

console.log("npm/ built:", readdirSync(out).join(", "));
