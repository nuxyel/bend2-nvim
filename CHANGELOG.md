# Changelog

## Unreleased

- Compiler discovery reads `bend guide`'s capabilities after the `bend version` fallback too: every Bend release
  since 2.0.35 refuses `--version`, so the JavaScript, native, GPU and thread capabilities were never read and
  showed as unknown.
- CI and the compiler dogfood pin Bend 2.0.40 as the latest tested version (2.0.32 before), with its checksums.

## 1.0.0 - 2026-09-28

- Native Bend filetype, syntax, indentation, snippets and upstream-aligned formatter.
- Parser-backed diagnostics, completion, signatures, symbols, navigation, references and rename.
- Bend compiler checks, proof workflows, backend execution/comparison, gates and benchmark reports.
- Proof Explorer with compiler-verified states and read-only law review.
- Linux/macOS CI and compiler dogfood across the declared Bend compatibility range.
- Asynchronous compiler-derived Bend Base completion with workspace cache and static fallback.
- A user-facing proof workflow example shared with the CI dogfood suite.
- Git-based installation through lazy.nvim, vim.pack, and Neovim's native package layout.
- Contribution, security, issue, and pull request guidance for repository collaborators.
