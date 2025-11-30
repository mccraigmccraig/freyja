# Benchmark comparing nested vs chained bind patterns
#
# Run with: mix run bench/queue_benchmark.exs
#
# This benchmark tests whether the O(n²) queue concatenation is a real
# problem in practice. We compare six patterns:
#
# 1. State/Nested  - Real effects at each step, nested binds (typical con/hefty usage)
# 2. State/Chained - Real effects at each step, chained binds (pathological)
# 3. Min/Nested    - Single effect then pure computation, nested binds
# 4. Min/Chained   - Single effect then pure computation, chained binds (isolates queue overhead)
# 5. Pure/Reduce   - Non-effectful baseline using Enum.reduce
# 6. Pure/Recurse  - Non-effectful baseline using recursion with map state access/update
#
# All measurements include both build and run time.

alias Freyja.Effects.State
alias Freyja.Freer
alias Freyja.Run

defmodule QueueBenchmark do
  # ============================================================
  # State effects - real work at each step
  # ============================================================

  # State/Nested: typical con macro expansion pattern
  # Queue stays short (1-2 items), builds incrementally during execution
  def state_nested(target) do
    state_nested_loop(target)
  end

  defp state_nested_loop(target) do
    State.get()
    |> Freer.bind(fn n ->
      if n >= target do
        Freer.pure(n)
      else
        State.put(n + 1)
        |> Freer.bind(fn _ ->
          state_nested_loop(target)
        end)
      end
    end)
  end

  # State/Chained: explicit bind chaining
  # Queue grows with each bind during construction
  def state_chained(target) do
    base = State.get()

    Enum.reduce(1..target, base, fn _i, acc ->
      acc
      |> Freer.bind(fn n ->
        if n >= target do
          Freer.pure(n)
        else
          State.put(n + 1)
          |> Freer.bind(fn _ ->
            State.get()
          end)
        end
      end)
    end)
  end

  # ============================================================
  # Minimal effect - isolates queue overhead
  # Uses a single State.get() as base, then chains identity binds
  # ============================================================

  # Min/Nested: nested identity binds
  # After initial State.get(), does pure computation with nested binds
  # Queue stays short, builds incrementally during execution
  def minimal_nested(target) do
    State.get()
    |> Freer.bind(fn _initial ->
      minimal_nested_loop(0, target)
    end)
  end

  defp minimal_nested_loop(n, target) do
    if n >= target do
      Freer.pure(n)
    else
      Freer.pure(n)
      |> Freer.bind(fn x ->
        minimal_nested_loop(x + 1, target)
      end)
    end
  end

  # Min/Chained: chained identity binds on an Impure base
  # Queue grows during construction - isolates O(n²) overhead
  # Note: bind on Pure immediately evaluates (monad law), so we need Impure base
  def minimal_chained(target) do
    base = State.get()

    Enum.reduce(1..target, base, fn _i, acc ->
      acc |> Freer.bind(fn x -> Freer.pure(x) end)
    end)
  end

  # ============================================================
  # Pure baselines - no effects, just computation
  # These establish the baseline cost of iteration with state access/update
  # ============================================================

  # Pure/Reduce: Enum.reduce with map state access and update
  # Mirrors the effectful pattern but without effect system overhead
  def pure_reduce(target) do
    initial_state = %{counter: 0}

    final_state =
      Enum.reduce(1..target, initial_state, fn _i, state ->
        n = Map.get(state, :counter)

        if n >= target do
          state
        else
          Map.put(state, :counter, n + 1)
        end
      end)

    Map.get(final_state, :counter)
  end

  # Pure/Recurse: recursive function with map state access and update
  # Mirrors the nested effectful pattern but without effect system overhead
  def pure_recurse(target) do
    initial_state = %{counter: 0}
    {result, _final_state} = pure_recurse_loop(target, initial_state)
    result
  end

  defp pure_recurse_loop(target, state) do
    n = Map.get(state, :counter)

    if n >= target do
      {n, state}
    else
      new_state = Map.put(state, :counter, n + 1)
      pure_recurse_loop(target, new_state)
    end
  end

  # ============================================================
  # Timing helpers
  # ============================================================

  def time_run(computation) do
    :timer.tc(fn ->
      computation
      |> State.Handler.run(0)
      |> Run.run()
    end)
  end

  def time_pure(fun) do
    :timer.tc(fun)
  end

  def run_benchmark(targets \\ [500, 1_000, 2_000, 5_000, 10_000]) do
    IO.puts("Queue Length Benchmark")
    IO.puts("======================")
    IO.puts("")
    IO.puts("Comparing nested vs chained binds, with and without real effect work.")
    IO.puts("Pure baselines show the cost of equivalent computation without effects.")
    IO.puts("All times include both construction and execution.")
    IO.puts("")

    # Warmup
    IO.puts("Warming up...")

    for _ <- 1..3 do
      _ = time_run(state_nested(100))
      _ = time_run(state_chained(100))
      _ = time_run(minimal_nested(100))
      _ = time_run(minimal_chained(100))
      _ = time_pure(fn -> pure_reduce(100) end)
      _ = time_pure(fn -> pure_recurse(100) end)
    end

    IO.puts("")

    iterations = 5

    IO.puts(
      String.pad_trailing("Target", 8) <>
        String.pad_trailing("State/Nest", 12) <>
        String.pad_trailing("State/Chain", 12) <>
        String.pad_trailing("Min/Nest", 12) <>
        String.pad_trailing("Min/Chain", 12) <>
        String.pad_trailing("Pure/Reduce", 12) <>
        String.pad_trailing("Pure/Recur", 12)
    )

    IO.puts(String.duplicate("-", 80))

    for target <- targets do
      # State/Nested
      state_nested_time =
        median_time(iterations, fn ->
          time_run(state_nested(target))
        end)

      # State/Chained
      state_chained_time =
        median_time(iterations, fn ->
          time_run(state_chained(target))
        end)

      # Minimal/Nested
      minimal_nested_time =
        median_time(iterations, fn ->
          time_run(minimal_nested(target))
        end)

      # Minimal/Chained
      minimal_chained_time =
        median_time(iterations, fn ->
          time_run(minimal_chained(target))
        end)

      # Pure/Reduce
      pure_reduce_time =
        median_time(iterations, fn ->
          time_pure(fn -> pure_reduce(target) end)
        end)

      # Pure/Recurse
      pure_recurse_time =
        median_time(iterations, fn ->
          time_pure(fn -> pure_recurse(target) end)
        end)

      IO.puts(
        String.pad_trailing("#{target}", 8) <>
          String.pad_trailing(format_time(state_nested_time), 12) <>
          String.pad_trailing(format_time(state_chained_time), 12) <>
          String.pad_trailing(format_time(minimal_nested_time), 12) <>
          String.pad_trailing(format_time(minimal_chained_time), 12) <>
          String.pad_trailing(format_time(pure_reduce_time), 12) <>
          String.pad_trailing(format_time(pure_recurse_time), 12)
      )
    end

    IO.puts("")
    IO.puts("Analysis:")
    IO.puts("---------")
    IO.puts("- State columns: Real State.get/put effects at each iteration")
    IO.puts("- Min columns: Single State.get, then N pure identity binds")
    IO.puts("- Pure columns: Non-effectful baselines with map state access/update")
    IO.puts("- Min/Chain isolates queue construction overhead (O(n²) if present)")
    IO.puts("- Compare State/Nest to Pure/Recur to see effect system overhead")
  end

  defp median_time(iterations, fun) do
    times =
      for _ <- 1..iterations do
        {time, _} = fun.()
        time
      end
      |> Enum.sort()

    Enum.at(times, div(iterations, 2))
  end

  defp format_time(microseconds) when microseconds < 1_000 do
    "#{microseconds} µs"
  end

  defp format_time(microseconds) when microseconds < 1_000_000 do
    "#{Float.round(microseconds / 1_000, 2)} ms"
  end

  defp format_time(microseconds) do
    "#{Float.round(microseconds / 1_000_000, 2)} s"
  end
end

QueueBenchmark.run_benchmark()
