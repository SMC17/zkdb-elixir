defmodule ZkdbElixir.SchedulingTest do
  # Large joins must not hold a normal scheduler. The VM's own monitor reports
  # any process that runs on a normal scheduler for longer than the threshold
  # without yielding; work moved to a dirty scheduler does not count.
  use ExUnit.Case, async: false

  @rows 1_000_000
  @threshold_ms 20

  defp long_schedules(fun) do
    :erlang.system_monitor(self(), [{:long_schedule, @threshold_ms}])
    parent = self()
    pid = spawn(fn -> send(parent, {:done, fun.()}) end)
    result = receive do {:done, r} -> r after 60_000 -> flunk("join did not finish") end
    :erlang.system_monitor(:undefined)
    events = collect(pid, [])
    {result, events}
  end

  defp collect(pid, acc) do
    receive do
      {:monitor, ^pid, :long_schedule, info} -> collect(pid, [info | acc])
    after 100 -> acc
    end
  end

  test "a 1M-row asof_join does not hold a normal scheduler" do
    left = Enum.to_list(1..@rows)
    right = Enum.to_list(0..(@rows - 1))
    {result, events} = long_schedules(fn -> ZkdbElixir.asof_join(left, right) end)
    assert length(result) == @rows
    assert List.last(result) == @rows - 1
    assert events == [], "normal scheduler held: #{inspect(events)}"
  end

  test "a 1M-row wj_sum does not hold a normal scheduler" do
    ts = Enum.to_list(1..@rows)
    syms = List.duplicate(0, @rows)
    data = List.duplicate(1.0, @rows)
    {result, events} = long_schedules(fn -> ZkdbElixir.wj_sum([0], [@rows], syms, ts, data, 9) end)
    assert result == [10.0]
    assert events == [], "normal scheduler held: #{inspect(events)}"
  end

  test "small joins still give the same answers" do
    assert ZkdbElixir.asof_join([1000, 2000], [500, 1500]) == [0, 1]
  end
end
