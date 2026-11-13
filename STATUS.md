# zkdb-elixir status

| | |
|---|---|
| Proof level | **unit-tested** (see [proof levels](https://github.com/SMC17/SMC17/blob/main/STANDARDS.md#proof-levels)) |
| Last verified | 2026-11-12, fresh clone, macOS on Apple M2 Max |
| Command | `mix test` |
| Result | 8/8 ExUnit tests pass, including 1M-row joins that must not hold a normal scheduler; mix builds the Zig NIF |

What is not claimed, and what comes next: [ROADMAP.md](ROADMAP.md) and the [open issues](https://github.com/SMC17/zkdb-elixir/issues).
