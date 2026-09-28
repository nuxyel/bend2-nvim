# Bend 2 compiler dogfood

The user-facing example and the CI dogfood fixture are the same project in
[`examples/proof-workflow`](../../examples/proof-workflow/README.md). This test
exercises import resolution, compiler-checked laws, JavaScript and native
execution, backend comparison and probing, benchmarking, and Proof Explorer
refresh. Run it with
`BEND2_BIN=/path/to/bend BEND_DOGFOOD_VERSION=2.0.28 nvim --headless -u NONE -l tests/dogfood.lua`.
The checksum-pinned compiler versions and supported platforms are listed in
`compiler-versions.json`.
