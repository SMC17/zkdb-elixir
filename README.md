# zkdb-elixir

**[Status](STATUS.md) · [Roadmap](ROADMAP.md) · [Contributing](CONTRIBUTING.md) · [Issues](https://github.com/SMC17/zkdb-elixir/issues) · [All SMC17 work](https://github.com/users/SMC17/projects/16)**

Elixir/OTP bindings for [zkdb](https://github.com/SMC17/zkdb) via Erlang NIF.

Zig data plane. Elixir control plane.

The hot paths (SIMD aggregation, asof join, window join) run in Zig with zero GC
jitter and manual memory. Elixir/OTP owns supervision, distribution, orchestration,
and protocol. Neither side pretends to do the other's job.

## Status

**Working prototype.** 8/8 ExUnit tests pass from a fresh clone (`mix test`).
Not published to Hex. Local path dep or GitHub dep for now.

## API

```elixir
# SIMD-accelerated sum over a float list
ZkdbElixir.sum_f64([1.0, 2.0, 3.0, 4.0, 5.0])
# → 15.0

# SIMD average
ZkdbElixir.avg_f64([2.0, 4.0, 6.0])
# → 4.0

# Asof join — for each left timestamp, index of last right timestamp ≤ left
ZkdbElixir.asof_join([1000, 2000, 3000], [500, 1500, 2500])
# → [0, 1, 2]

ZkdbElixir.asof_join([100], [200, 300])
# → [:nil]  (no right timestamp ≤ 100)

# Window join sum — for each left (sym_id, ts), sum right data in [ts-window, ts]
ZkdbElixir.wj_sum(
  [0],              # sym_l  — symbol IDs (integer, pre-interned)
  [1000],           # ts_l   — left timestamps (nanoseconds)
  [0, 0, 0],        # sym_r
  [100, 500, 900],  # ts_r
  [1.0, 2.0, 3.0],  # data_r
  1000              # window_ns
)
# → [6.0]   (100+500+900 all within [0..1000], sum = 1+2+3)
```

All sym arguments are pre-interned integer IDs. Symbol-to-ID mapping lives in
Elixir; the Zig layer never sees strings on the hot path.

## Architecture

```
Elixir (OTP)
  GenServer / DynamicSupervisor / Registry
       │
       │  :erlang.call/NIF
       ▼
Zig (zkdb_nif.so)
  sum_f64 / avg_f64 / asof_join / wj_sum
  │
  (self-contained ports of the zkdb SIMD sum,
   asof-join and window-join kernels)
```

The NIF uses an Arena allocator per call — no cross-call state, no GC pressure
on the BEAM scheduler.

## Build

**Requirements**: Zig 0.16, Erlang/OTP 27+, Elixir 1.17+, with `erl` on PATH.

```sh
mix test
```

`mix compile` runs `zig build` in `native/zkdb_nif` and copies the library to
`priv/zkdb_nif.so`. The Erlang headers are found from `erl` on PATH; override
with `cd native/zkdb_nif && zig build -Derlang-root=/path/to/erlang`.

Fresh clone, 2026-11-12, macOS aarch64, OTP 28, Elixir 1.18.5, Zig 0.16.0:
8/8 ExUnit tests pass.

## Composing with OTP

The intended pattern is: Zig for the column-level operation, Elixir for the
row-selection, supervision, and scheduling logic.

```elixir
defmodule PriceServer do
  use GenServer

  def handle_call({:window_sum, sym_id, ts, window_ns}, _from, state) do
    result = ZkdbElixir.wj_sum(
      [sym_id], [ts],
      state.sym_r, state.ts_r, state.data_r,
      window_ns
    )
    {:reply, hd(result), state}
  end
end
```

Inputs of 10,000 elements or more are moved to a dirty CPU scheduler with
`enif_schedule_nif`, so a large join never holds a normal BEAM scheduler;
smaller inputs run in place. `test/scheduling_test.exs` checks this with the
VM's `long_schedule` monitor: before the change, a 1M-row `asof_join` held a
normal scheduler for 617 ms; after it, no event above 20 ms.

## Roadmap

- [x] Dirty scheduler for large inputs (10,000+ elements)
- [ ] Binary term format (ETF) for large vector transfer — avoid list overhead
- [ ] Resource types for persistent zkdb Table handles (no copy per call)
- [ ] `wj_avg`, `wj_last`, `wj_min`, `wj_max` NIF variants
- [x] Mix compiler builds the NIF automatically
- [ ] Depend on zkdb directly instead of carrying ported kernels
- [ ] Hex package once API stabilizes

## License

Apache-2.0. See [LICENSE](LICENSE).
