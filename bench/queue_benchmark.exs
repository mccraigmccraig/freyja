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
# 11. Skuld/Chained - Skuld library with chained binds (tests CPS queue behavior)
# 12. Skuld/FxList - Skuld with FxList: all iterations inside single computation
#
# All measurements include both build and run time.

alias Freyja.Effects.State
alias Freyja.Freer
alias Freyja.Run
alias Skuld.Effects.State, as: SkuldState
alias Skuld.Effects.FxList, as: SkuldFxList
alias Skuld.Effects.Yield, as: SkuldYield

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

  # Evf/Single: all benchmark iterations in a single run
  # This pays handler setup ONCE across all iterations
  def evf_single(target, benchmark_iterations) do
    total_ops = target * benchmark_iterations
    evf_with_state(0, evf_nested_loop(total_ops))
  end

  # ============================================================
  # Skuld - evidence-passing library with CPS for control effects
  # ============================================================

  alias Skuld.Comp

  # Skuld/Nested: Skuld library with nested binds
  # Uses the actual Skuld library implementation
  # Queue stays short (CPS style), builds incrementally during execution
  def skuld_nested(target) do
    skuld_nested_loop(target)
  end

  defp skuld_nested_loop(target) do
    SkuldState.get()
    |> Comp.bind(fn n ->
      if n >= target do
        Comp.pure(n)
      else
        SkuldState.put(n + 1)
        |> Comp.bind(fn _ ->
          skuld_nested_loop(target)
        end)
      end
    end)
  end

  # Skuld/Chained: Skuld library with chained binds
  # Tests whether Skuld's CPS style avoids O(n²) queue overhead
  def skuld_chained(target) do
    base = SkuldState.get()

    Enum.reduce(1..target, base, fn _i, acc ->
      acc
      |> Comp.bind(fn n ->
        if n >= target do
          Comp.pure(n)
        else
          SkuldState.put(n + 1)
          |> Comp.bind(fn _ ->
            SkuldState.get()
          end)
        end
      end)
    end)
  end

  # Skuld/FxList: All iterations inside a single computation
  # But NOTE: each Comp.run() still pays scoped handler setup/teardown
  def skuld_fxlist(target) do
    SkuldFxList.fx_each(1..target, fn _i ->
      SkuldState.get()
      |> Comp.bind(fn n ->
        SkuldState.put(n + 1)
      end)
    end)
    |> Comp.bind(fn _ ->
      SkuldState.get()
    end)
  end

  # Skuld/FxList "single": benchmark iterations * target iterations all in ONE Comp.run()
  # This truly pays handler setup/teardown ONCE across all benchmark iterations
  def skuld_fxlist_single(target, benchmark_iterations) do
    total_ops = target * benchmark_iterations

    SkuldFxList.fx_each(1..total_ops, fn _i ->
      SkuldState.get()
      |> Comp.bind(fn n ->
        SkuldState.put(n + 1)
      end)
    end)
    |> Comp.bind(fn _ ->
      SkuldState.get()
    end)
    |> SkuldState.with_handler(0)
  end

  # ============================================================
  # Skuld/Yield: Coroutine approach - handler setup ONCE, short continuation chains
  # ============================================================

  # A looping computation that does one iteration then yields
  # The continuation chain stays small (just one iteration's worth)
  # Matches FxList work: State.get + State.put per iteration
  def skuld_yield_loop() do
    SkuldState.get()
    |> Comp.bind(fn n ->
      SkuldState.put(n + 1)
    end)
    |> Comp.bind(fn _ ->
      # Yield :ok, then loop when resumed
      SkuldYield.yield(:ok)
      |> Comp.bind(fn _input ->
        skuld_yield_loop()
      end)
    end)
  end

  # Pre-wrapped computation with all handlers installed
  def skuld_yield_wrapped(initial_state) do
    skuld_yield_loop()
    |> SkuldYield.with_handler()
    |> SkuldState.with_handler(initial_state)
  end

  # Run N iterations using yield/resume pattern
  # Handler setup happens ONCE, then we resume N times
  def time_skuld_yield(target) do
    wrapped = skuld_yield_wrapped(0)
    iterations_remaining = target

    driver = fn _yielded_value ->
      # We use process dictionary to track iterations (simpler than threading state)
      remaining = Process.get(:yield_iterations, iterations_remaining)

      if remaining > 1 do
        Process.put(:yield_iterations, remaining - 1)
        {:continue, :ok}
      else
        Process.delete(:yield_iterations)
        {:stop, :done}
      end
    end

    Process.put(:yield_iterations, iterations_remaining)

    :timer.tc(fn ->
      SkuldYield.run_with_driver(wrapped, driver)
    end)
  end

  # ============================================================
  # Timing helpers
  # ============================================================

  # Freyja: RunBuilder must be constructed per-run (consumed by Run.run)
  # We time only the Run.run() call, not the builder construction
  def time_freyja(computation, initial_state) do
    builder =
      computation
      |> State.Handler.run(initial_state)

    :timer.tc(fn ->
      Run.run(builder)
    end)
  end

  def time_pure(fun) do
    :timer.tc(fun)
  end

  def time_monad(computation, initial_state) do
    :timer.tc(fn ->
      monad_run(computation, initial_state)
    end)
  end

  def time_ev(computation) do
    # ev_with_state is part of the computation, so we just run it
    :timer.tc(fn ->
      ev_run(computation, %{evidence: %{}})
    end)
  end

  def time_evf(computation) do
    # evf_with_state is part of the computation, so we just run it
    :timer.tc(fn ->
      evf_run(computation, %{})
    end)
  end

  # Skuld: pre-wrapped computation can be reused (just a function)
  def time_skuld_wrapped(wrapped_computation) do
    :timer.tc(fn ->
      Comp.run(wrapped_computation)
    end)
  end

  # Skuld: wrap + run (for warmup or when we want to include setup)
  def skuld_wrap(computation, initial_state) do
    computation |> SkuldState.with_handler(initial_state)
  end

  def run_benchmark(targets \\ [500, 1_000, 2_000, 5_000, 10_000]) do
    IO.puts("Queue Length Benchmark")
    IO.puts("======================")
    IO.puts("")
    IO.puts("Comparing nested vs chained binds, with and without real effect work.")
    IO.puts("Pure baselines show the cost of equivalent computation without effects.")
    IO.puts("Handler setup is done ONCE per measurement; only execution is timed.")
    IO.puts("")

    # Warmup
    IO.puts("Warming up...")

    for _ <- 1..3 do
      _ = time_freyja(state_nested(100), 0)
      _ = time_freyja(state_chained(100), 0)
      _ = time_freyja(minimal_nested(100), 0)
      _ = time_freyja(minimal_chained(100), 0)
      _ = time_pure(fn -> pure_reduce(100) end)
      _ = time_pure(fn -> pure_recurse(100) end)
      _ = time_monad(monad_nested(100), 0)
      _ = time_ev(ev_nested(100))
      _ = time_evf(evf_nested(100))
      _ = time_skuld_wrapped(skuld_wrap(skuld_nested(100), 0))
      _ = time_skuld_wrapped(skuld_wrap(skuld_chained(100), 0))
      _ = time_skuld_wrapped(skuld_wrap(skuld_fxlist(100), 0))
      # Single-run variants
      _ = time_evf(evf_single(100, 10))
      _ = time_skuld_wrapped(skuld_fxlist_single(100, 10))
      # Yield variant
      _ = time_skuld_yield(100)
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
        String.pad_trailing("Skuld/Nest", 12) <>
        String.pad_trailing("Skuld/Chain", 12) <>
        String.pad_trailing("Skuld/FxL", 12)
    )

    IO.puts(String.duplicate("-", 152))

    for target <- targets do
      # Build computations once per target
      state_nested_comp = state_nested(target)
      state_chained_comp = state_chained(target)
      minimal_nested_comp = minimal_nested(target)
      minimal_chained_comp = minimal_chained(target)
      monad_nested_comp = monad_nested(target)
      ev_nested_comp = ev_nested(target)
      evf_nested_comp = evf_nested(target)

      # Skuld: wrap once, reuse for all iterations (handlers installed once)
      skuld_nested_wrapped = skuld_wrap(skuld_nested(target), 0)
      skuld_chained_wrapped = skuld_wrap(skuld_chained(target), 0)
      skuld_fxlist_wrapped = skuld_wrap(skuld_fxlist(target), 0)

      # State/Nested (Freyja) - builder constructed per iteration, only run() timed
      state_nested_time =
        median_time(iterations, fn ->
          time_freyja(state_nested_comp, 0)
        end)

      # State/Chained (Freyja)
      state_chained_time =
        median_time(iterations, fn ->
          time_freyja(state_chained_comp, 0)
        end)

      # Minimal/Nested (Freyja)
      minimal_nested_time =
        median_time(iterations, fn ->
          time_freyja(minimal_nested_comp, 0)
        end)

      # Minimal/Chained (Freyja)
      minimal_chained_time =
        median_time(iterations, fn ->
          time_freyja(minimal_chained_comp, 0)
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
          time_monad(monad_nested_comp, 0)
        end)

      # Ev/Nested
      ev_nested_time =
        median_time(iterations, fn ->
          time_ev(ev_nested_comp)
        end)

      # Evf/Nested
      evf_nested_time =
        median_time(iterations, fn ->
          time_evf(evf_nested_comp)
        end)

      # Skuld/Nested - wrapped once, run() timed multiple times
      skuld_nested_time =
        median_time(iterations, fn ->
          time_skuld_wrapped(skuld_nested_wrapped)
        end)

      # Skuld/Chained - wrapped once, run() timed multiple times
      skuld_chained_time =
        median_time(iterations, fn ->
          time_skuld_wrapped(skuld_chained_wrapped)
        end)

      # Skuld/FxList - all iterations inside single computation
      skuld_fxlist_time =
        median_time(iterations, fn ->
          time_skuld_wrapped(skuld_fxlist_wrapped)
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
          String.pad_trailing(format_time(skuld_nested_time), 12) <>
          String.pad_trailing(format_time(skuld_chained_time), 12) <>
          String.pad_trailing(format_time(skuld_fxlist_time), 12)
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
    IO.puts("- Skuld/Chain: Skuld library with chained binds (tests CPS queue behavior)")
    IO.puts("- Skuld/FxL: Skuld with FxList - all iterations inside single computation")
    IO.puts("")
    IO.puts("- Min/Chain isolates queue construction overhead (O(n²) if present)")
    IO.puts("- Compare State/Nest to Skuld/Nest to see Freyja vs Skuld performance")
    IO.puts("- Compare Skuld/Nest to Skuld/Chain to verify CPS avoids O(n²) queue overhead")
    IO.puts("- Compare Skuld/FxL to Skuld/Nest to see benefit of single-computation iteration")
    IO.puts("- Compare Skuld/FxL to Evf/Nest to see Skuld overhead vs minimal evidence-passing")
    IO.puts("- Compare Evf/Nest to Monad/Nest to see cost of dynamic handler dispatch")
    IO.puts("- Compare Monad/Nest to Pure/Recur to see state monad abstraction overhead")

    # ============================================================
    # Single-Run Benchmark: Handler setup paid ONCE
    # ============================================================
    # ============================================================
    # Yield Benchmark: Coroutine approach - best of both worlds
    # ============================================================
    IO.puts("")
    IO.puts("")
    IO.puts("Yield Benchmark (Coroutine Approach)")
    IO.puts("====================================")
    IO.puts("")
    IO.puts("Yield uses coroutine-style suspend/resume: handler setup ONCE,")
    IO.puts("short continuation chains (one iteration at a time).")
    IO.puts("Extended targets to show scaling advantage at large N.")
    IO.puts("")

    # Extended targets for yield benchmark to show scaling advantage
    yield_targets = [1_000, 5_000, 10_000, 50_000, 100_000]

    IO.puts(
      String.pad_trailing("Target", 10) <>
        String.pad_trailing("Skuld/FxL", 15) <>
        String.pad_trailing("Skuld/Yield", 15) <>
        String.pad_trailing("FxL µs/op", 12) <>
        String.pad_trailing("Yield µs/op", 12) <>
        String.pad_trailing("Speedup", 10)
    )

    IO.puts(String.duplicate("-", 75))

    for target <- yield_targets do
      # FxList timing
      skuld_fxlist_wrapped = skuld_wrap(skuld_fxlist(target), 0)

      skuld_fxlist_time =
        median_time(iterations, fn ->
          time_skuld_wrapped(skuld_fxlist_wrapped)
        end)

      # Yield timing
      skuld_yield_time =
        median_time(iterations, fn ->
          time_skuld_yield(target)
        end)

      # Per-op calculations
      fxlist_per_op = skuld_fxlist_time / target
      yield_per_op = skuld_yield_time / target

      # Speedup: FxList / Yield
      yield_speedup = if skuld_yield_time > 0, do: skuld_fxlist_time / skuld_yield_time, else: 0

      IO.puts(
        String.pad_trailing("#{target}", 10) <>
          String.pad_trailing(format_time(skuld_fxlist_time), 15) <>
          String.pad_trailing(format_time(skuld_yield_time), 15) <>
          String.pad_trailing("#{Float.round(fxlist_per_op, 3)}", 12) <>
          String.pad_trailing("#{Float.round(yield_per_op, 3)}", 12) <>
          String.pad_trailing("#{Float.round(yield_speedup, 2)}x", 10)
      )
    end

    IO.puts("")
    IO.puts("Yield Analysis:")
    IO.puts("---------------")
    IO.puts("- Skuld/Yield maintains ~constant per-op cost as N grows")
    IO.puts("- At large N, Yield is significantly faster than FxList")
    IO.puts("- Yield achieves O(n) scaling by avoiding long continuation chains")
    IO.puts("- Handler setup paid ONCE, short chains avoid memory pressure")

    # ============================================================
    # Single-Run Benchmark: For reference (shows FxList scaling issue)
    # ============================================================
    IO.puts("")
    IO.puts("")
    IO.puts("Single-Run Benchmark (FxList Scaling Issue)")
    IO.puts("===========================================")
    IO.puts("")
    IO.puts("FxList with large N shows super-linear (~O(n^1.3)) scaling due to")
    IO.puts("memory/cache pressure from long continuation chains.")
    IO.puts("")

    # Use a multiplier to amortize setup cost
    multiplier = 100

    IO.puts(
      String.pad_trailing("Target", 10) <>
        String.pad_trailing("Evf/Single", 15) <>
        String.pad_trailing("Skuld/Single", 15) <>
        String.pad_trailing("Evf/Nest", 15) <>
        String.pad_trailing("Skuld/FxL", 15) <>
        String.pad_trailing("Slowdown", 10)
    )

    IO.puts(String.duplicate("-", 80))

    for target <- targets do
      # Single-run: do (target * multiplier) ops in ONE run, divide time by multiplier
      evf_single_comp = evf_single(target, multiplier)
      skuld_single_comp = skuld_fxlist_single(target, multiplier)

      # For comparison: normal per-run timing (from above)
      evf_nested_comp = evf_nested(target)
      skuld_fxlist_wrapped = skuld_wrap(skuld_fxlist(target), 0)

      # Time single-run variants (run once, time includes all target*multiplier ops)
      {evf_single_total_time, _} = time_evf(evf_single_comp)
      evf_single_per_target = evf_single_total_time / multiplier

      {skuld_single_total_time, _} = time_skuld_wrapped(skuld_single_comp)
      skuld_single_per_target = skuld_single_total_time / multiplier

      # Normal timing for comparison
      evf_nested_time =
        median_time(iterations, fn ->
          time_evf(evf_nested_comp)
        end)

      skuld_fxlist_time =
        median_time(iterations, fn ->
          time_skuld_wrapped(skuld_fxlist_wrapped)
        end)

      # Slowdown: how much slower is single-run vs normal (shows scaling issue)
      slowdown =
        if skuld_fxlist_time > 0, do: skuld_single_per_target / skuld_fxlist_time, else: 0

      IO.puts(
        String.pad_trailing("#{target}", 10) <>
          String.pad_trailing(format_time(round(evf_single_per_target)), 15) <>
          String.pad_trailing(format_time(round(skuld_single_per_target)), 15) <>
          String.pad_trailing(format_time(evf_nested_time), 15) <>
          String.pad_trailing(format_time(skuld_fxlist_time), 15) <>
          String.pad_trailing("#{Float.round(slowdown, 2)}x", 10)
      )
    end

    IO.puts("")
    IO.puts("Single-Run Analysis:")
    IO.puts("--------------------")
    IO.puts("- Slowdown > 1 means FxList with large N is slower per-op than small N")
    IO.puts("- This demonstrates the ~O(n^1.3) scaling issue in FxList")
    IO.puts("- Evf/Single ~= Evf/Nest (pure CPS scales linearly)")
    IO.puts("- Root cause: long continuation chains cause memory/cache pressure")
    IO.puts("")
    IO.puts("SOLUTION: Use Skuld/Yield for large iteration counts!")
    IO.puts("- Yield maintains O(n) scaling by keeping continuation chains short")
    IO.puts("- Handler setup paid once, coroutine-style resume for each iteration")
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
