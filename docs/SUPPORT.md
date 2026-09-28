# Support policy

## Compatibility

| Component | Supported baseline |
| --- | --- |
| Neovim | 0.11 or newer |
| Bend compiler | 2.0.28 or newer in the 2.x line |
| Host | Linux x86-64 and macOS arm64; Windows through WSL |
| Node.js | Not required |
| Optional Neovim plugins | None required |

Without `bend`, parser diagnostics, syntax, formatting and source navigation
remain available. Compiler-backed status is never inferred as verified.

The compatibility matrix covers Bend 2.0.28 (minimum) and 2.0.32 (latest tested
for v1). Update the tested latest version and its published checksums before
tagging a stable release. Workspace indexing is bounded to 5,000 Bend files and
skips `.git`, `.bend`, `node_modules`, `dist`, `build` and `target` directories.

## Reporting issues

Run `:Bend2Support` and include its source-free report, Neovim version, Bend
version/revision, host and plugin commit. Review the report before sharing it.
