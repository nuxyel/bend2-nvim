# Bend 2 proof workflow

This small project demonstrates the Bend 2 editor and compiler workflow used
by the Neovim plugin's dogfood checks:

- `main.bend` and `app.bend` demonstrate modules and imports.
- `LAWS.bend` and `PROOF.bend` show a law and a compiler-checked proof.
- `run.bend` is a small program used for JavaScript and native backend runs.

From the repository root, open the project in Neovim:

```sh
nvim examples/proof-workflow/main.bend
```

With the plugin configured and Bend 2.0.28 or newer available on `PATH`, run
`:Bend2CheckWorkspace` to check the proof suite. Use `:Bend2Proofs` to open the
Proof Explorer and `:Bend2RefreshProofExplorer` to refresh compiler-derived
proof states. The CI dogfood command additionally runs and compares the
JavaScript and native backends.

To run the complete dogfood suite from the repository root:

```sh
BEND2_BIN=/path/to/bend BEND_DOGFOOD_VERSION=2.0.28 \
  nvim --headless -u NONE -l tests/dogfood.lua
```

The same example files are used by CI; there is no separate copy of the
project fixture.
