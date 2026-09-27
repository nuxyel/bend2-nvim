# Development

## Requirements

- Neovim 0.11 or newer.
- LuaJIT (provided by standard Neovim builds).
- Bend 2.0.28 and 2.0.32 for compiler dogfood.

## Checks

```sh
nvim --headless -u NONE -l tests/run.lua
nvim --headless -u NONE -l tests/dogfood.lua
```

Tests run inside Neovim and do not require Node or third-party Lua packages.
Dogfood needs the `bend` compiler on PATH.

## Commit policy

Keep commits atomic and scoped to one subsystem. Run the applicable headless
checks before committing, and do not mix unrelated fixes into a feature commit.
