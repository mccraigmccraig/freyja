defmodule Freyja.Run do
  @moduledoc """
  Execute both Freer and Hefty computations using a pipe-friendly builder API.

  This module provides a unified interface for running both first-order (Freer)
  and higher-order (Hefty) effect computations.

  ## Freer Computations (First-Order Effects)

  For Freer computations with only first-order effects:

      outcome = computation
        |> State.Handler.run(0)
        |> Writer.Handler.run([])
        |> Run.run()

  ## Hefty Computations (Higher-Order Effects)

  For Hefty computations with higher-order effects, compose algebras and handlers:

      outcome = hefty_computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(0)
        |> Throw.Handler.run()
        |> Run.run()

  ## RunBuilder Pattern

  The pipe API uses `RunBuilder` to compose effect handlers and algebras:

  - Each handler/algebra's `.run()` method adds it to the builder
  - Handlers can specify initial state: `Handler.run(initial_state)`
  - Handlers can use defaults: `Handler.run()` (uses `default_initial_state/0` if available)
  - The final `Run.run()` executes the builder and returns a `RunOutcome`

  ## Helper Functions

  - `Run.eval(builder)` - Execute and return only the result value
  - `Run.exec(builder)` - Execute and return only the handler outputs
  - `Run.resume(builder, outcome_or_map, value)` - Resume a suspended computation (live or serialized)
  - `Run.rerun(builder, outcome)` - Rerun with outputs from previous run as initial states

  ## Two-Phase Execution for Hefty

  When running Hefty computations:

  **Phase 1: Elaboration** - Algebras transform higher-order effects into first-order effects
  **Phase 2: Interpretation** - Handlers execute the first-order effects

  Based on "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects"
  (Poulsen & van der Rest, POPL 2023).

  ## See Also

  - `Freyja.Run.RunBuilder` - Builder for composing effect pipelines
  - `Freyja.Hefty.Elaborate` - Elaboration catamorphism for Hefty
  - `Freyja.Hefty.Algebra` - Algebra behavior
  - `Freyja.Freer.EffectHandler` - Effect handler behavior
  """
  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.EffectLogger
  alias Freyja.Hefty.Elaborate
  alias Freyja.Run.Impl
  alias Freyja.Run.RunBuilder
  alias Freyja.Run.RunState
  alias Freyja.Run.RunOutcome

  require Logger

  # RunBuilder API - Pipe-friendly execution

  @doc """
  Execute a RunBuilder and return the full RunOutcome.

  This is the primary execution function for the pipe-friendly builder API.

  ## Examples

      # Freer computation
      outcome = computation
        |> State.Handler.run(0)
        |> Writer.Handler.run([])
        |> Run.run()

      # Hefty computation
      outcome = hefty_computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(0)
        |> Run.run()

      # Pure computation (no handlers needed)
      outcome = Hefty.pure(42) |> Run.run()
  """
  @spec run(RunBuilder.t()) :: RunOutcome.t()
  def run(%RunBuilder{} = builder) do
    case builder.computation_type do
      :hefty ->
        # Phase 1: Elaborate with algebras
        freer = Elaborate.elaborate(builder.computation, builder.algebras)
        # Phase 2: Interpret with handlers
        run_freer(freer, builder.handlers)

      :freer ->
        # Just interpret with handlers
        run_freer(builder.computation, builder.handlers)
    end
  end

  # Handle raw computations by auto-creating an empty RunBuilder
  def run(computation) do
    RunBuilder.new(computation) |> run()
  end

  @doc """
  Execute a RunBuilder and return only the result value.

  Equivalent to `run(builder).result`.

  ## Examples

      result = computation
        |> State.Handler.run(5)
        |> Run.eval()

      # Pure computation
      result = Hefty.pure(42) |> Run.eval()  # returns 42
  """
  @spec eval(RunBuilder.t()) :: any
  def eval(%RunBuilder{} = builder) do
    run(builder).result
  end

  # Handle raw computations
  def eval(computation) do
    run(computation).result
  end

  @doc """
  Execute a RunBuilder and return only the handler outputs/states.

  Equivalent to `run(builder).outputs`.

  ## Examples

      outputs = computation
        |> State.Handler.run(0)
        |> Writer.Handler.run([])
        |> Run.exec()
  """
  @spec exec(RunBuilder.t()) :: map
  def exec(%RunBuilder{} = builder) do
    run(builder).outputs
  end

  # Handle raw computations
  def exec(computation) do
    run(computation).outputs
  end

  # Private helper for RunBuilder execution
  defp run_freer(computation, handler_tuples) do
    # Convert handler tuples to handler specs
    handler_specs =
      Enum.map(handler_tuples, fn {mod, state} ->
        {mod, {mod, state}}
      end)

    run_state = RunState.new(handler_specs)
    Impl.run_with_state(computation, run_state)
  end

  @doc """
  Resume a suspended computation with a value.

  Accepts the original builder along with either the live `RunOutcome` returned by
  `Run.run/1` or a serialized map (e.g., decoded JSON). When the outcome contains
  runtime continuation state the resume happens immediately. Otherwise the builder
  is rerun using the recorded outputs to reconstruct the continuation before resuming.
  """
  def resume(%RunBuilder{} = builder, %RunOutcome{} = outcome, input) do
    resume_with_builder(builder, outcome, input)
  end

  def resume(%RunBuilder{} = builder, outcome_map, input) when is_map(outcome_map) do
    outcome = RunOutcome.from_json(outcome_map)
    resume_with_builder(builder, outcome, input)
  end

  # "hot" resume - we still have a continuation
  defp resume_with_builder(
         _builder,
         %RunOutcome{result: {:suspend, _value, k}, run_state: %RunState{} = run_state},
         input
       )
       when is_function(k, 1) do
    Impl.do_run(k.(input), run_state)
  end

  # "cold" resume - probably from a deserialized RunOutcome, with the
  # unserializable continuation erased
  defp resume_with_builder(
         %RunBuilder{} = builder,
         %RunOutcome{result: {:suspend, _value, _k}, run_state: nil} = outcome,
         input
       ) do
    outcome = enable_log_divergence(outcome)

    builder
    |> builder_with_outputs(outcome.outputs)
    |> inject_coroutine_resume_value(input)
    |> run()
  end

  defp resume_with_builder(_builder, %RunOutcome{result: other}, _input) do
    raise ArgumentError,
          "Run.resume expected a suspended outcome, got: #{inspect(other)}"
  end

  @doc """
  Rerun a RunBuilder using outputs from a previous run as the initial states.

  This is useful for replay/resume scenarios where you want to use logged states.

  Supports both live outcomes returned from `Run.run/1` and serialized checkpoints
  (e.g., `outcome |> Jason.encode!() |> Jason.decode!()`).

  ## Examples

      builder = computation |> State.Handler.run(0)
      outcome1 = Run.run(builder)
      outcome2 = Run.rerun(builder, outcome1)

      # Cold rerun from serialized outcome
      json = Jason.encode!(outcome1)
      decoded = Jason.decode!(json)
      outcome3 = Run.rerun(builder, decoded)
  """
  def rerun(%RunBuilder{} = builder, %RunOutcome{} = outcome) do
    outcome = enable_log_divergence(outcome)

    builder
    |> builder_with_outputs(outcome.outputs)
    |> run()
  end

  def rerun(%RunBuilder{} = builder, outcome_map) when is_map(outcome_map) do
    outcome =
      outcome_map
      |> RunOutcome.from_json()

    rerun(builder, outcome)
  end

  defp enable_log_divergence(%RunOutcome{} = outcome) do
    updated_outputs =
      Enum.reduce(outcome.outputs, %{}, fn
        {EffectLogger.Handler, %EffectLogger.Log{} = log}, acc ->
          Map.put(acc, EffectLogger.Handler, EffectLogger.Log.for_error_resume(log))

        {key, value}, acc ->
          Map.put(acc, key, value)
      end)

    %{outcome | outputs: updated_outputs}
  end

  defp builder_with_outputs(%RunBuilder{} = builder, outputs) when is_map(outputs) do
    updated_handlers =
      Enum.map(builder.handlers, fn {mod, _old_state} ->
        {mod, Map.get(outputs, mod)}
      end)

    %{builder | handlers: updated_handlers}
  end

  defp inject_coroutine_resume_value(%RunBuilder{} = builder, resume_value) do
    updated_handlers =
      Enum.map(builder.handlers, fn
        {Coroutine.Handler = mod, state} ->
          new_state =
            state
            |> normalize_coroutine_state()
            |> Map.put(:resume_value, resume_value)

          {mod, new_state}

        handler ->
          handler
      end)

    %{builder | handlers: updated_handlers}
  end

  defp normalize_coroutine_state(nil), do: %{}
  defp normalize_coroutine_state(state) when is_map(state), do: state
  defp normalize_coroutine_state(state), do: %{state: state}
end
