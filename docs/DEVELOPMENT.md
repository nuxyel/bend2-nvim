# Development

## Requirements

- Neovim 0.11 or newer.
- LuaJIT (provided by standard Neovim builds).
- Bend 2.0.28 and 2.0.32 for compiler dogfood.
- Node.js is not required by the plugin.

## Checks

```sh
nvim --headless -u NONE -l tests/run.lua
BEND2_BIN=/path/to/bend BEND_DOGFOOD_VERSION=2.0.28 nvim --headless -u NONE -l tests/dogfood.lua
BEND2_BIN=/path/to/bend BEND_DOGFOOD_VERSION=2.0.32 nvim --headless -u NONE -l tests/dogfood.lua
```

Tests run inside Neovim and do not require Node or third-party Lua packages.
Dogfood needs the `bend` compiler on PATH.

CI covers Neovim 0.11.7 and 0.12.5 on Linux x86-64 and macOS arm64, and Bend
2.0.28/2.0.32 on both hosts. Windows users are supported through WSL and use
the Linux test path.

The formatter in `lua/bend2/formatter.lua` is a Lua port of the official
`bend-fmt-lsp` formatting contract. When the reference changes, update the Lua
port and fixtures from `../bend2-vscode/packages/language-server/src/officialFormatter.ts`.

Keep the plugin version in `lua/bend2/version.lua`. A stable version must have
the same version heading in `CHANGELOG.md`; the unit suite checks this metadata.
See [RELEASING.md](RELEASING.md) for the v1 release gate.

## Commit policy

Keep commits atomic and scoped to one subsystem. Run the applicable headless
checks before committing, and do not mix unrelated fixes into a feature commit.
Keep runtime changes, compiler compatibility, platform/CI changes and release
documentation in separate commits. Community-health files and issue templates
also get focused commits apart from runtime changes. Repository labels are GitHub
metadata and are configured separately from Git commits.
