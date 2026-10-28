#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 felixdrp
//
// Entry point of the npm package's `gcf` bin (bundled to dist/cli.js).
import { main } from "./cli.ts";
import { init } from "./index.ts";

process.exitCode = main(process.argv.slice(2), await init());
