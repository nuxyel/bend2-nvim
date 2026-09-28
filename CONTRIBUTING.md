# Contributing

Thanks for helping improve Bend2.nvim. Bug reports, focused feature requests,
documentation updates, and pull requests are welcome.

## Before opening an issue

Use the issue forms for bugs and feature requests. For a bug, include the
Neovim and plugin versions, Bend version when available, operating system,
steps to reproduce, and the behavior you expected. Remove private source code,
tokens, paths, and other sensitive data from logs.

For substantial changes, open a feature request first so the approach can be
discussed before implementation.

## Development setup

- Neovim 0.11 or newer.
- LuaJIT from a standard Neovim build.
- Bend 2.0.28 and 2.0.32 for compiler dogfood checks.
- Node.js and third-party Lua packages are not required.

Run the unit suite before committing:

```sh
nvim --headless -u NONE -l tests/run.lua
```

Run compiler dogfood with each supported compiler version:

```sh
BEND2_BIN=/path/to/bend BEND_DOGFOOD_VERSION=2.0.28 nvim --headless -u NONE -l tests/dogfood.lua
BEND2_BIN=/path/to/bend BEND_DOGFOOD_VERSION=2.0.32 nvim --headless -u NONE -l tests/dogfood.lua
```

For runtime changes, run the relevant unit checks and dogfood path. CI covers
Linux x86-64 and macOS arm64 with Neovim 0.11.7 and 0.12.5.

## Pull requests and commits

- Keep each commit atomic and scoped to one subsystem or documentation concern.
- Make separate commits for runtime behavior, tests, compiler compatibility,
  platform/CI changes, release metadata, and community documentation when they
  are independent.
- Run the applicable headless checks before committing; do not mix unrelated
  fixes into a feature commit.
- Describe user-visible behavior and tests in the pull request. Update user
  documentation and `CHANGELOG.md` when behavior or support changes.
- Do not add default key mappings or new external dependencies without first
  discussing the user impact.

There is no required commit-message convention, but concise imperative subjects
make history easier to scan.

## License

By contributing, you agree that your contribution is provided under the
project's Apache-2.0 license. Keep existing copyright and `NOTICE` attribution
when modifying vendored or adapted material.
