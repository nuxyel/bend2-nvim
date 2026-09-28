# Releasing

Bend2.nvim is distributed as a public Git repository. SemVer Git tags are the
version source used by Neovim plugin managers; no separate package registry,
LuaRocks upload, marketplace listing, or compiled archive is needed. GitHub
generates source archives for each tag. See [INSTALLATION.md](INSTALLATION.md)
for user installation paths.

## Required checks

1. Run `nvim --headless -u NONE -l tests/run.lua` on Neovim 0.11.7 and 0.12.5.
2. Run `tests/dogfood.lua` with Bend 2.0.28 (the minimum supported version) and
   the latest supported Bend release. Record published SHA-256 pins in CI and
   `tests/dogfood/compiler-versions.json`.
3. Confirm the CI matrix is green on Linux x86-64 and macOS arm64. Windows
   support means Neovim and Bend run inside WSL; the Linux job is its execution
   baseline.
4. Review formatter parity, compiler diagnostics, proof statuses, workspace
   navigation and rename, cancellation, backend capabilities, and benchmark
   reports.
5. Check command/configuration documentation and verify the plugin starts
   without optional Neovim plugins or Node.js.

## Publishing a release

1. Keep `lua/bend2/version.lua` and the matching `CHANGELOG.md` heading on the
   same SemVer version. Update the changelog before tagging.
2. Run all applicable local checks and the full CI matrix. Inspect
   `git diff --check` and confirm the working tree is clean.
3. Keep each correction in its own focused commit. Do not combine release
   metadata changes with runtime behavior changes.
4. Create an annotated `v<major>.<minor>.<patch>` tag only after CI passes.
   Create the GitHub Release from that tag and publish the matching changelog
   section as release notes. Do not upload redundant compiled assets.

The stable `v1.0.0` tag and GitHub Release have been published. Any code or
release metadata change after a release must pass the full CI matrix before
publishing another tag.
