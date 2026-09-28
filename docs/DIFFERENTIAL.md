# Backend comparison

`:Bend2CompareBackends` prompts for two or more comma-separated profiles:
`javascript`, `native` and `gpu`. Results are comparable only when every run
finishes successfully; stdout hashes determine whether outputs match.

For workspace comparisons, create `.bend2/differential.json`:

```json
{
  "files": ["main.bend", "app.bend"],
  "profiles": ["javascript", "native"],
  "threads": 2,
  "gpuMemory": "on"
}
```

`files` must be existing workspace-relative `.bend` files. `profiles` must
contain at least two distinct supported names. `threads` must be a positive
integer when set. `gpuMemory` accepts `on` or a limit such as `4GB`. Paths
outside the workspace are rejected.

`:Bend2Benchmark` compiles once per thread-count/GPU configuration, discards
one warm-up run per configuration, measures the requested run count, checks output stability,
and writes a JSON report under `.bend/benchmarks/`. Benchmark results are
machine-specific observations, not promises of speedup.
