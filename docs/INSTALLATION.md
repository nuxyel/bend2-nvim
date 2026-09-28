# Installation

Bend2.nvim is distributed as a Git repository. There is no separate binary
package or LuaRocks release: the plugin is pure Lua and its plugin managers
install the tagged Git source directly. Stable releases use SemVer tags such
as `v1.0.0`.

The repository is private during the initial release. You need Git access to
`nuxyel/bend2-nvim` and credentials already configured for your chosen Git
transport. After the repository becomes public, the same specifications work
without private-repository credentials.

## lazy.nvim

Works with the supported Neovim 0.11 and 0.12 versions:

```lua
{
  "nuxyel/bend2-nvim",
  version = "^1.0.0",
  config = function()
    require("bend2").setup()
  end,
}
```

If your private Git setup uses SSH rather than HTTPS, set the plugin's `url`
to `git@github.com:nuxyel/bend2-nvim.git`.

## Neovim `vim.pack`

Neovim 0.12 and newer include `vim.pack`. It installs directly from the Git
repository and follows SemVer tags. The API is currently documented as
experimental, so lazy.nvim remains a supported option as well.

```lua
vim.pack.add({
  {
    src = "https://github.com/nuxyel/bend2-nvim",
    version = vim.version.range("1.0"),
  },
})

require("bend2").setup()
```

Use an SSH `src` if that is how your Git credentials are configured for the
private repository.

## Native package layout

Neovim 0.11 users who do not use a plugin manager can clone the repository to
`stdpath("data")/site/pack/bend2/start/bend2-nvim`. Find the data directory
with `:echo stdpath('data')`. Check out a stable version tag, then add
`require("bend2").setup()` to your Neovim configuration.

## Bend compiler

The plugin's editing features work without Bend installed. Compiler-backed
checks, proof workflows, Bend Base completion, builds and execution require
Bend 2.0.28 or newer on `PATH`, or a configured `cmd` in `setup()`.
