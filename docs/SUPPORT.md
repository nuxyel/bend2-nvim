# Support policy

## Compatibility

| Component | Supported baseline |
| --- | --- |
| Neovim | 0.11 or newer |
| Bend compiler | 2.0.28 or newer in the 2.x line |
| Host | Linux and macOS; Windows through WSL |
| Node.js | Not required |
| Optional Neovim plugins | None required |

Without `bend`, parser diagnostics, syntax, formatting and source navigation
remain available. Compiler-backed status is never inferred as verified.

The initial dogfood matrix uses Bend 2.0.28 and 2.0.32. Update the tested latest
version from the compiler release matrix before tagging a stable release.

## Reporting issues

Run `:Bend2Support` and include its source-free report, Neovim version, Bend
version/revision, host and plugin commit. Review the report before sharing it.
