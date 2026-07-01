defmodule ZkdbElixirTest do
  use ExUnit.Case

  test "sum_f64 SIMD" do
    assert ZkdbElixir.sum_f64([1.0, 2.0, 3.0, 4.0, 5.0]) == 15.0
  end

  test "avg_f64" do
    assert ZkdbElixir.avg_f64([2.0, 4.0, 6.0]) == 4.0
  end

  test "asof_join basic" do
    # left_ts = [1000, 2000, 3000], right_ts = [500, 1500, 2500]
    # 1000 → last right ≤ 1000 = index 0 (ts=500)
    # 2000 → last right ≤ 2000 = index 1 (ts=1500)
    # 3000 → last right ≤ 3000 = index 2 (ts=2500)
    result = ZkdbElixir.asof_join([1000, 2000, 3000], [500, 1500, 2500])
    assert result == [0, 1, 2]
  end

  test "asof_join no-match" do
    # left_ts = [100], right_ts = [200, 300] → no match → nil
    result = ZkdbElixir.asof_join([100], [200, 300])
    assert result == [:nil]
  end

  test "wj_sum window join" do
    # AAPL (sym 0): left at ts=1000; right at ts=100,500,900 with prices 1,2,3
    # window=1000: [0..1000] → ts 100,500,900 → sum=6.0
    result = ZkdbElixir.wj_sum(
      [0],        # sym_l
      [1000],     # ts_l
      [0, 0, 0],  # sym_r
      [100, 500, 900],  # ts_r
      [1.0, 2.0, 3.0],  # data_r
      1000        # window_ns
    )
    assert result == [6.0]
  end
end
