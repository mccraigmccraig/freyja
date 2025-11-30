# Flame graph profiling for Freyja effect system
#
# Run with: mix run bench/flamegraph_benchmark.exs
#
# This generates flame graphs for different computation patterns to identify
# where time is being spent in the effect system.
#
# Output files are written to bench/flamegraphs/

alias Freyja.Effects.State
alias Freyja.Freer
alias Freyja.Run

defmodule FlamegraphBenchmark do
  @output_dir "bench/flamegraphs"

  # ============================================================
  # Computation patterns (same as queue_benchmark.exs)
  # ============================================================

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

  def minimal_chained(target) do
    base = State.get()

    Enum.reduce(1..target, base, fn _i, acc ->
      acc |> Freer.bind(fn x -> Freer.pure(x) end)
    end)
  end

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
  # Flame graph generation
  # ============================================================

  def run_computation(computation) do
    computation
    |> State.Handler.run(0)
    |> Run.run()
  end

  def profile(name, fun) do
    File.mkdir_p!(@output_dir)

    IO.puts("Profiling #{name}...")

    # eflambe captures a flame graph - it writes to current directory with timestamp
    # We'll capture the filename it generates and rename it
    before_files = list_bggg_files(".")

    :eflambe.apply({fun, []}, output_format: :brendan_gregg)

    after_files = list_bggg_files(".")
    new_files = after_files -- before_files

    case new_files do
      [generated_file] ->
        target_file = Path.join(@output_dir, "#{name}.bggg")
        File.rename!(generated_file, target_file)
        size = File.stat!(target_file).size
        IO.puts("  -> #{target_file} (#{format_size(size)})")

      _ ->
        IO.puts("  -> Warning: Could not identify generated file")
    end
  end

  defp list_bggg_files(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".bggg"))
    |> Enum.map(&Path.join(dir, &1))
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  def run_profiles(target \\ 2000) do
    IO.puts("Flame Graph Profiling")
    IO.puts("=====================")
    IO.puts("")
    IO.puts("Target iterations: #{target}")
    IO.puts("Output directory: #{@output_dir}/")
    IO.puts("")

    # Warmup
    IO.puts("Warming up...")
    _ = run_computation(state_nested(100))
    _ = run_computation(minimal_nested(100))
    _ = pure_recurse(100)
    IO.puts("")

    # Profile each pattern
    profile("state_nested_#{target}", fn ->
      run_computation(state_nested(target))
    end)

    profile("state_chained_#{target}", fn ->
      run_computation(state_chained(target))
    end)

    profile("minimal_nested_#{target}", fn ->
      run_computation(minimal_nested(target))
    end)

    profile("minimal_chained_#{target}", fn ->
      run_computation(minimal_chained(target))
    end)

    profile("pure_recurse_#{target}", fn ->
      pure_recurse(target)
    end)

    IO.puts("")
    IO.puts("Done! Flame graph files written to #{@output_dir}/")
    IO.puts("")
    IO.puts("To view flame graphs:")
    IO.puts("  1. Install flamegraph.pl: https://github.com/brendangregg/FlameGraph")
    IO.puts("  2. Convert to SVG:")

    IO.puts(
      "     cat #{@output_dir}/state_nested_#{target}.bggg | flamegraph.pl > state_nested.svg"
    )

    IO.puts("  3. Open the SVG in a browser")
    IO.puts("")
    IO.puts("Or use speedscope.app (drag and drop the .bggg file)")
  end
end

FlamegraphBenchmark.run_profiles()
