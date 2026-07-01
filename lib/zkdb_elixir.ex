defmodule ZkdbElixir do
  @moduledoc """
  zkdb Elixir bindings — Zig data plane, Elixir control plane.

  The Zig NIF handles all hot paths: SIMD aggregation, asof join,
  window join. Elixir owns orchestration, supervision, and protocol.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    nif_path = Path.join([Application.app_dir(:zkdb_elixir, "priv"), "zkdb_nif"])
    :erlang.load_nif(String.to_charlist(nif_path), 0)
  end

  @doc """
  SIMD-accelerated sum of a float list.

      iex> ZkdbElixir.sum_f64([1.0, 2.0, 3.0, 4.0, 5.0])
      15.0
  """
  def sum_f64(_list), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  SIMD-accelerated average of a float list.

      iex> ZkdbElixir.avg_f64([1.0, 2.0, 3.0])
      2.0
  """
  def avg_f64(_list), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Asof join: for each timestamp in left_ts, find the index of the
  last right_ts <= left_ts. Returns a list of indices (nil for no match).

      iex> ZkdbElixir.asof_join([1000, 2000, 3000], [500, 1500, 2500])
      [0, 1, 2]
  """
  def asof_join(_left_ts, _right_ts), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Window join sum: for each left (sym, ts), sum all right data values
  where right.sym == sym AND ts - window_ns <= right.ts <= ts.

  All sym arguments are lists of integer IDs (pre-interned).
  """
  def wj_sum(_sym_l, _ts_l, _sym_r, _ts_r, _data_r, _window_ns),
    do: :erlang.nif_error(:nif_not_loaded)
end
