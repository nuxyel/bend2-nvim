# Private v1 release gate

The v1 release is distributed as a private Git repository release. No public
plugin registry or marketplace is part of this release.

## Required checks

1. Run `nvim --headless -u NONE -l tests/run.lua` on Neovim 0.11.7 and 0.12.5.
2. Run `tests/dogfood.lua` with Bend 2.0.28 (the minimum supported version) and
   the latest supported Bend release. Both compiler archives must have their
   published SHA-256 pins recorded in CI and `tests/dogfood/compiler-versions.json`.
3. Confirm the CI matrix is green on Linux x86-64 and macOS arm64. Windows
   support means Neovim and Bend run inside WSL; the Linux job is its execution
   baseline.
4. Review formatter parity with the upstream Bend formatter, compiler
   diagnostics fixtures, proof statuses, workspace navigation and rename,
   cancellation, backend capability handling, and generated benchmark reports.
5. Check the complete command/configuration documentation and verify that the
   plugin starts without optional Neovim plugins or Node.js.

## Preparing the private tag

1. Confirm `lua/bend2/version.lua` and the dated heading in `CHANGELOG.md` both
   identify version 1.0.0. If either changes, rerun the complete CI matrix.
2. Update the latest Bend dogfood version and checksums from the official Bend
   release page; retain Bend 2.0.28 as the minimum compatibility check.
3. Run all applicable local checks, inspect `git diff --check`, and confirm
   `git status --short` is empty.
4. Keep each remaining correction in its own focused commit. Do not combine
   release metadata changes with runtime behavior changes.
5. Create an annotated `v1.0.0` tag only after the complete CI matrix passes.
   Create a private GitHub release from that tag and attach the source archive
   and changelog. Verify the repository and release are private before sharing
   access with testers.

The checked-in 1.0.0 candidate has passed the required CI matrix. Keep tag
creation and the private GitHub release as a separate maintainer step; any code
or release metadata change after that CI run must pass the matrix again first.
