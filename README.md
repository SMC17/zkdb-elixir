# zkdb-elixir

Elixir/OTP bindings for [zkdb](https://github.com/SMC17/zkdb) via Erlang NIF.

Zig data plane. Elixir control plane.

The hot paths (SIMD aggregation, asof join, window join) run in Zig with zero GC
jitter and manual memory. Elixir/OTP owns supervision, distribution, orchestration,
and protocol. Neither side pretends to do the other's job.

## Status

**Working prototype.** 5/5 ExUnit tests pass. NIF loads cleanly under OTP 28.
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
  │  @import("zkdb")
  ▼
zkdb primitives
  vector.zig (SIMD)  asof.zig  wj.zig
```

The NIF uses an Arena allocator per call — no cross-call state, no GC pressure
on the BEAM scheduler.

## Build

**Requirements**: Zig 0.16+, Erlang/OTP 27+, Elixir 1.17+

```sh
# 1. Build the Zig NIF shared library
cd native/zkdb_nif
zig build -Doptimize=ReleaseFast

# 2. Copy the .so to priv/
mkdir -p ../../priv
cp zig-out/lib/libzkdb_nif.so ../../priv/zkdb_nif.so

# 3. Run Elixir tests
cd ../..
mix test
```

The `@on_load :load_nif` in `ZkdbElixir` loads `priv/zkdb_nif.so` at module
load time. If the .so is missing, all NIF calls raise `:nif_not_loaded`.

## Erlang root

The NIF build detects the Erlang root automatically via `-Derlang-root=<path>`.
Default is `/home/stax/.local/share/mise/installs/erlang/28.5`. Override:

```sh
zig build -Derlang-root=$(erl -noshell -eval 'io:format("~s", [code:root_dir()])' -s init stop)
```

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

For large datasets, run the NIF on a dirty scheduler to avoid blocking the BEAM:
this is on the roadmap; current calls use the default scheduler (suitable for
sub-millisecond operations).

## Roadmap

- [ ] Dirty scheduler for long-running joins (>1ms)
- [ ] Binary term format (ETF) for large vector transfer — avoid list overhead
- [ ] Resource types for persistent zkdb Table handles (no copy per call)
- [ ] `wj_avg`, `wj_last`, `wj_min`, `wj_max` NIF variants
- [ ] Mix task to build NIF automatically (`mix zkdb.build`)
- [ ] Hex package once API stabilizes

## License

AGPL-3.0. See [LICENSE](LICENSE).
