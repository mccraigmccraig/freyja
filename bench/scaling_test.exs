# Micro-benchmark to test iteration scaling in Skuld
#
# Run with: mix run bench/scaling_test.exs

alias Skuld.Comp
alias Skuld.Effects.State, as: SkuldState
alias Skuld.Effects.FxList, as: SkuldFxList

defmodule ScalingTest do
  def skuld_fxlist(n) do
    SkuldFxList.fx_each(1..n, fn _i ->
      SkuldState.get()
      |> Comp.bind(fn x ->
        SkuldState.put(x + 1)
      end)
    end)
    |> SkuldState.with_handler(0)
  end

  def time_it(label, n) do
    comp = skuld_fxlist(n)
    {time, _} = :timer.tc(fn -> Comp.run(comp) end)
    per_op = time / n
    IO.puts("#{label}: #{n} ops in #{div(time, 1000)}ms = #{Float.round(per_op, 3)}µs/op")
    {n, time, per_op}
  end
end

IO.puts("Skuld FxList Scaling Test")
IO.puts("=========================")
IO.puts("")

# Warmup
_ = Comp.run(ScalingTest.skuld_fxlist(100))
_ = Comp.run(ScalingTest.skuld_fxlist(100))

results = [
  ScalingTest.time_it("    500", 500),
  ScalingTest.time_it("  1,000", 1_000),
  ScalingTest.time_it("  2,000", 2_000),
  ScalingTest.time_it("  5,000", 5_000),
  ScalingTest.time_it(" 10,000", 10_000),
  ScalingTest.time_it(" 20,000", 20_000),
  ScalingTest.time_it(" 50,000", 50_000),
  ScalingTest.time_it("100,000", 100_000)
]

IO.puts("")
IO.puts("If linear: per-op time should be constant")
IO.puts("If O(n²): per-op time should grow linearly with n")
