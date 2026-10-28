#!/usr/bin/env bun
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// gcf — command-line codec, repository build (uses dist/gcf.wasm).
//   bun bin/gcf.ts encode|decode|stats [file]
//   node --experimental-strip-types bin/gcf.ts ...
// The npm package ships the same CLI as `gcf` (src/cli-npm.ts).
import { readFileSync } from "node:fs";
import { main } from "../src/cli.ts";
import { GcfCodec } from "../src/host.ts";

const gcf = await GcfCodec.instantiate(readFileSync(new URL("../dist/gcf.wasm", import.meta.url)));
process.exitCode = main(process.argv.slice(2), gcf);
