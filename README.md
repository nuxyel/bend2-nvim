# Bend 2 for Neovim

Native Lua editing support and developer tools for Bend 2. This repository is
private during initial development; install it from Git with an account that
has repository access.

## Requirements

- Neovim 0.11 or newer.
- Bend 2 2.0.28 or newer for compiler-backed features.
- No Node.js, language-server executable, or optional Neovim plugins.

Editing features remain available without the Bend compiler. Compiler results
are authoritative; parser-derived diagnostics and proof statuses are marked as
inferred.

## Installation

With lazy.nvim:

```lua
{
  "nuxyel/bend2-nvim",
  url = "git@github.com:nuxyel/bend2-nvim.git",
  config = function()
    require("bend2").setup()
  end,
}
```

The plugin is also compatible with Neovim's native package layout. Clone it to
`~/.local/share/nvim/site/pack/bend2/start/bend2-nvim` and call
`require("bend2").setup()` from your config.

## Commands

Run `:Bend2Help` for the complete command list. `:Bend2Snippet` inserts the
bundled function, law, match and parallel-call templates. Commands have no default key
maps. Use `:Bend2Proofs` to browse laws and proofs. Use `:Bend2Check` to run a
compiler check without executing `main()`.

## Configuration

```lua
require("bend2").setup({
  cmd = "bend",
  cmd_args = {},
  root_markers = { ".git" },
  validation = "on_save", -- parser | on_save | on_type | off
  diagnostics_mode = "auto", -- auto | text | json
  auto_import = false,
  formatter = true,
})
```

See [docs/SUPPORT.md](docs/SUPPORT.md), [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md),
and [CHANGELOG.md](CHANGELOG.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
