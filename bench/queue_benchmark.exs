# Benchmark comparing nested vs chained bind patterns
#
# Run with: mix run bench/queue_benchmark.exs
#
# This benchmark tests whether the O(n²) queue concatenation is a real
# problem in practice. We compare patterns:
#
# 1. State/Nested  - Real effects at each step, nested binds (typical con/hefty usage)
# 2. State/Chained - Real effects at each step, chained binds (pathological)
# 3. Min/Nested    - Single effect then pure computation, nested binds
# 4. Min/Chained   - Single effect then pure computation, chained binds (isolates queue overhead)
# 5. Pure/Reduce   - Non-effectful baseline using Enum.reduce
# 6. Pure/Recurse  - Non-effectful baseline using recursion with map state access/update
# 7. Monad/Nested  - Simple state monad (no transformer), nested binds
# 8. Ev/Nested     - Evidence-passing style: state monad + evidence map for handler dispatch
# 9. Evf/Nested    - Flat evidence-passing: handlers as direct env keys (single map lookup)
# 10. Skuld/Nested - Skuld library: evidence-passing with CPS for control effects
#
# All measurements include both build and run time.

alias Freyja.Effects.State
alias Freyja.Freer
alias Freyja.Run
alias Skuld.Effects.State, as: SkuldState

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
  # Simple State Monad - no transformers, just state -> {a, state}
  # This represents the simplest possible state monad implementation
  # ============================================================

  # A state monad is just a function: state -> {value, new_state}
  # We represent it as a 0-arity function that takes state when called

  def monad_pure(value) do
    fn state -> {value, state} end
  end

  def monad_get() do
    fn state -> {state, state} end
  end

  def monad_put(new_state) do
    fn _state -> {:ok, new_state} end
  end

  def monad_bind(ma, f) do
    fn state ->
      {a, state2} = ma.(state)
      mb = f.(a)
      mb.(state2)
    end
  end

  def monad_run(ma, initial_state) do
    ma.(initial_state)
  end

  # Monad/Nested: simple state monad with nested binds
  # Mirrors state_nested but using simple state monad instead of Freyja effects
  def monad_nested(target) do
    monad_nested_loop(target)
  end

  defp monad_nested_loop(target) do
    monad_get()
    |> monad_bind(fn n ->
      if n >= target do
        monad_pure(n)
      else
        monad_put(n + 1)
        |> monad_bind(fn _ ->
          monad_nested_loop(target)
        end)
      end
    end)
  end

  # ============================================================
  # Evidence-passing style - dynamic evidence map + state monad
  # Models Koka-style evidence passing as a library
  # ============================================================

  # Evidence-passing computation: fn env -> {value, env}
  # where env = %{evidence: %{effect_key => handler}, ...other_state...}
  #
  # This avoids:
  # - Impure node allocation (direct handler call instead)
  # - Queue concatenation (state monad style continuation)
  # - Pattern matching on signatures (map lookup instead)

  def ev_pure(value) do
    fn env -> {value, env} end
  end

  def ev_bind(ma, f) do
    fn env ->
      {a, env2} = ma.(env)
      mb = f.(a)
      mb.(env2)
    end
  end

  def ev_run(ma, initial_env) do
    ma.(initial_env)
  end

  # Perform an effect operation - looks up handler in evidence map and calls it
  # The handler receives: (args, resume_fn, env) where resume_fn is the continuation
  def ev_perform(effect_key, op_key, args) do
    fn env ->
      handler = env.evidence[effect_key][op_key]
      # Handler is called with args and a "resume" function
      # Resume function takes a value and returns a computation
      handler.(args, env)
    end
  end

  # State effect operations using evidence-passing
  def ev_state_get() do
    ev_perform(:state, :get, [])
  end

  def ev_state_put(value) do
    ev_perform(:state, :put, value)
  end

  # State handler - installs handlers into evidence map
  def ev_with_state(initial_state, computation) do
    fn env ->
      state_handlers = %{
        get: fn _args, inner_env ->
          state = inner_env.state
          {state, inner_env}
        end,
        put: fn new_state, inner_env ->
          {:ok, %{inner_env | state: new_state}}
        end
      }

      # Install evidence and initial state
      evidence = Map.get(env, :evidence, %{})
      inner_env = %{env | evidence: Map.put(evidence, :state, state_handlers)}
      inner_env = Map.put(inner_env, :state, initial_state)

      # Run computation with evidence installed
      {result, final_env} = computation.(inner_env)

      # Return result, restore outer env (remove our state)
      {result, Map.delete(final_env, :state)}
    end
  end

  # Ev/Nested: evidence-passing style with nested binds
  def ev_nested(target) do
    ev_with_state(0, ev_nested_loop(target))
  end

  defp ev_nested_loop(target) do
    ev_state_get()
    |> ev_bind(fn n ->
      if n >= target do
        ev_pure(n)
      else
        ev_state_put(n + 1)
        |> ev_bind(fn _ ->
          ev_nested_loop(target)
        end)
      end
    end)
  end

  # ============================================================
  # Evidence-passing "flat" - handlers as direct env keys
  # Avoids nested map lookups entirely
  # ============================================================

  def evf_pure(value) do
    fn env -> {value, env} end
  end

  def evf_bind(ma, f) do
    fn env ->
      {a, env2} = ma.(env)
      mb = f.(a)
      mb.(env2)
    end
  end

  def evf_run(ma, initial_env) do
    ma.(initial_env)
  end

  # Direct handler lookup - single map access
  def evf_state_get() do
    fn env ->
      env.state_get.(env)
    end
  end

  def evf_state_put(value) do
    fn env ->
      env.state_put.(value, env)
    end
  end

  # Flat state handler - puts handlers directly in env
  def evf_with_state(initial_state, computation) do
    fn env ->
      inner_env =
        env
        |> Map.put(:state, initial_state)
        |> Map.put(:state_get, fn inner_env -> {inner_env.state, inner_env} end)
        |> Map.put(:state_put, fn new_state, inner_env ->
          {:ok, %{inner_env | state: new_state}}
        end)

      {result, final_env} = computation.(inner_env)
      {result, Map.drop(final_env, [:state, :state_get, :state_put])}
    end
  end

  # Evf/Nested: flat evidence-passing style with nested binds
  def evf_nested(target) do
    evf_with_state(0, evf_nested_loop(target))
  end

  defp evf_nested_loop(target) do
    evf_state_get()
    |> evf_bind(fn n ->
      if n >= target do
        evf_pure(n)
      else
        evf_state_put(n + 1)
        |> evf_bind(fn _ ->
          evf_nested_loop(target)
        end)
      end
    end)
  end

  # ============================================================
  # Skuld - evidence-passing library with CPS for control effects
  # ============================================================

  # Skuld/Nested: Skuld library with nested binds
  # Uses the actual Skuld library implementation
  def skuld_nested(target) do
    skuld_nested_loop(target)
  end

  defp skuld_nested_loop(target) do
    SkuldState.get()
    |> Skuld.bind(fn n ->
      if n >= target do
        Skuld.pure(n)
      else
        SkuldState.put(n + 1)
        |> Skuld.bind(fn _ ->
          skuld_nested_loop(target)
        end)
      end
    end)
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

  def time_monad(computation) do
    :timer.tc(fn ->
      monad_run(computation, 0)
    end)
  end

  def time_ev(computation) do
    :timer.tc(fn ->
      ev_run(computation, %{evidence: %{}})
    end)
  end

  def time_evf(computation) do
    :timer.tc(fn ->
      evf_run(computation, %{})
    end)
  end

  def time_skuld(computation) do
    :timer.tc(fn ->
      env = Skuld.Env.new() |> SkuldState.handler(0)
      Skuld.run(computation, env)
    end)
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
      _ = time_monad(monad_nested(100))
      _ = time_ev(ev_nested(100))
      _ = time_evf(evf_nested(100))
      _ = time_skuld(skuld_nested(100))
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
        String.pad_trailing("Pure/Recur", 12) <>
        String.pad_trailing("Monad/Nest", 12) <>
        String.pad_trailing("Ev/Nest", 12) <>
        String.pad_trailing("Evf/Nest", 12) <>
        String.pad_trailing("Skuld/Nest", 12)
    )

    IO.puts(String.duplicate("-", 128))

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

      # Monad/Nested
      monad_nested_time =
        median_time(iterations, fn ->
          time_monad(monad_nested(target))
        end)

      # Ev/Nested
      ev_nested_time =
        median_time(iterations, fn ->
          time_ev(ev_nested(target))
        end)

      # Evf/Nested
      evf_nested_time =
        median_time(iterations, fn ->
          time_evf(evf_nested(target))
        end)

      # Skuld/Nested
      skuld_nested_time =
        median_time(iterations, fn ->
          time_skuld(skuld_nested(target))
        end)

      IO.puts(
        String.pad_trailing("#{target}", 8) <>
          String.pad_trailing(format_time(state_nested_time), 12) <>
          String.pad_trailing(format_time(state_chained_time), 12) <>
          String.pad_trailing(format_time(minimal_nested_time), 12) <>
          String.pad_trailing(format_time(minimal_chained_time), 12) <>
          String.pad_trailing(format_time(pure_reduce_time), 12) <>
          String.pad_trailing(format_time(pure_recurse_time), 12) <>
          String.pad_trailing(format_time(monad_nested_time), 12) <>
          String.pad_trailing(format_time(ev_nested_time), 12) <>
          String.pad_trailing(format_time(evf_nested_time), 12) <>
          String.pad_trailing(format_time(skuld_nested_time), 12)
      )
    end

    IO.puts("")
    IO.puts("Analysis:")
    IO.puts("---------")
    IO.puts("- State columns: Real State.get/put effects at each iteration (Freyja freer monad)")
    IO.puts("- Min columns: Single State.get, then N pure identity binds")
    IO.puts("- Pure columns: Non-effectful baselines with map state access/update")
    IO.puts("- Monad/Nest: Simple state monad (fn state -> {val, state} end) with nested binds")
    IO.puts("- Ev/Nest: Evidence-passing - nested map lookup %{effect => %{op => handler}}")
    IO.puts("- Evf/Nest: Flat evidence - single map lookup %{state_get => handler}")
    IO.puts("- Skuld/Nest: Skuld library - evidence-passing with CPS for control effects")
    IO.puts("")
    IO.puts("- Min/Chain isolates queue construction overhead (O(n²) if present)")
    IO.puts("- Compare State/Nest to Skuld/Nest to see Freyja vs Skuld performance")
    IO.puts("- Compare Skuld/Nest to Evf/Nest to see overhead of CPS + outcome handling")
    IO.puts("- Compare Evf/Nest to Monad/Nest to see cost of dynamic handler dispatch")
    IO.puts("- Compare Monad/Nest to Pure/Recur to see state monad abstraction overhead")
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
