# Publishing guide

How to publish gcf-wasm under the `felixdrp` name. Nothing here has been
published yet. This repository includes
[gcf-zig](https://codeberg.org/felixdrp/gcf-zig) as a git submodule, so
publish gcf-zig first.

| Artefact | Where | Name |
|---|---|---|
| npm package | npmjs.com | `@felixdrp/gcf-wasm` |
| WebAssembly modules | Release assets | `gcf.wasm`, the hand-written WAT codec without debug names; `gcf_simd.wasm` and `gcf_simd.relaxed.wasm`, the SIMD structural indexer (+ `SHA256SUMS`) |

## 0. Before the first release

* [ ] **Copyright holder.** The files say "Copyright 2026 felixdrp". If the
  work was done as part of an employment or university role, confirm with
  the institution's IP policy that you may publish it under your name.
* [ ] **Attribution.** Review `NOTICE`: it credits Blackwell Systems for the
  GCF specification and gcf-typescript, which `src/host.ts` and the WAT
  encoder modules adapt.
* [ ] **Release date.** Set the date in `CHANGELOG.md`.
* [ ] **Local checks.** `bun run test && bun run test:oracle && bun run pack:npm`.
  Then inspect `npm/*.tgz`, e.g. `tar -tzf npm/*.tgz`.

## 1. Repository

Create an empty repository `felixdrp/gcf-wasm` on GitHub (no README, licence or
.gitignore), push gcf-zig first, then:

```sh
git remote add origin git@github.com:felixdrp/gcf-wasm.git
git push -u origin main
```

`.gitmodules` already points the submodule at
`https://codeberg.org/felixdrp/gcf-zig.git`. A local checkout made before
gcf-zig was pushed may still use a local path; after the push, run
`git submodule sync` to switch it to the URL in `.gitmodules`.

On GitHub:

* **Description.** "Fast, strict GCF codec: 93 KB hand-written WebAssembly
  (SIMD) + npm".
* **Topics.** `webassembly`, `wasm`, `wat`, `simd`, `gcf`, `llm`,
  `serialization`.
* **CI.** `.github/workflows/ci.yml` runs on every push. These workflows have
  not been run yet, so check the first run.

## 2. npm

1. Create or log in to the npm account **felixdrp** (the scope `@felixdrp`
   belongs to it) and enable two-factor authentication.
2. Pick one way to publish from CI:
   * **Trusted publishing (recommended):** on npmjs.com, link the package to
     the GitHub repository and the `release.yml` workflow. No token needed.
   * **Token:** create an *automation* token and store it as the repository
     secret `NPM_TOKEN`.
3. Manual alternative, without CI:

   ```sh
   bun run pack:npm               # builds and packs npm/felixdrp-gcf-wasm-X.Y.Z.tgz
   cd npm && npm publish --access public
   ```

   `--access public` is required the first time a scoped package is
   published.

## 3. Releasing a version

1. Bump the version in `npm/package.json` (it must match the tag), then
   update `CHANGELOG.md`, including the gcf-zig version the release is
   tested against (the submodule commit).
2. Commit, tag and push:

   ```sh
   git tag v0.1.0 && git push origin v0.1.0
   ```

3. `.github/workflows/release.yml` then:
   * checks the tag against the package version;
   * runs the tests, including the comparison with the Zig reference build;
   * attaches `gcf.wasm` (`dist/gcf.wasm`, checked to be identical to the
     npm package's), the SIMD structural indexer (`gcf_simd.wasm`,
     `gcf_simd.relaxed.wasm`) and `SHA256SUMS` to a release;
   * publishes `@felixdrp/gcf-wasm` with provenance.

## 4. After the release

* **Blackwell's implementations list.** Ask Blackwell Systems to list the
  project in the *Implementations* table of
  [blackwell-systems/gcf](https://github.com/blackwell-systems/gcf), together
  with gcf-zig.
* **Verify the installs.** Try `npm install @felixdrp/gcf-wasm` and
  `npx @felixdrp/gcf-wasm --help` from a clean machine.

## Versioning rules

* **Breaking changes** to the JS API or the wasm ABI require a major
  version bump (minor while in 0.x). Any wasm ABI change also bumps
  `gcf_abi_version` (`src/wat/01_core.wat`) and `docs/WASM_ABI.md`, and is
  made in gcf-zig first (`abi_version` in `src/wasm.zig`).
* **Spec support.** The supported GCF specification version is stated in
  the changelog. Spec changes go into gcf-zig first, then here, gated by
  `bun run test:oracle`.
