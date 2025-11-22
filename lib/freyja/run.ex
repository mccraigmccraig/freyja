defmodule Freyja.Run do
  @moduledoc """
  Execute both Freer and Hefty computations.

  This module provides a unified interface for running both first-order (Freer)
  and higher-order (Hefty) effect computations.

  ## Freer Computations (First-Order Effects)

  For Freer computations with only first-order effects:

      Run.run(
        computation,
        [State.Handler, Writer.Handler],
        %{State.Handler => 0}
      )

  ## Hefty Computations (Higher-Order Effects)

  For Hefty computations with higher-order effects, provide algebras as the
  second parameter:

      Run.run(
        hefty_computation,
        [Catch.Algebra, Lift.Algebra],      # Elaboration phase
        [State.Handler, Error.Handler],     # Interpretation phase
        %{State.Handler => 0}
      )

  The function automatically detects whether you're running Freer or Hefty
  based on the computation structure and arity.

  ## Two-Phase Execution for Hefty

  When running Hefty computations:

  **Phase 1: Elaboration** - Transform higher-order effects into first-order effects
  **Phase 2: Interpretation** - Execute first-order effects using handlers

  Based on "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects"
  (Poulsen & van der Rest, POPL 2023).

  ## See Also

  - `Freyja.Hefty.Elaborate` - Elaboration catamorphism for Hefty
  - `Freyja.Hefty.Algebra` - Algebra behavior
  - Effect handlers implement `Freyja.Freer.EffectHandler` behavior
  """
  alias Freyja.Freer
  alias Freyja.Hefty
  alias Freyja.Hefty.Elaborate
  alias Freyja.Hefty.Sig.IHeftySendable
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

  @doc """
  Execute a RunBuilder and return only the result value.

  Equivalent to `run(builder).result`.

  ## Examples

      result = computation
        |> State.Handler.run(5)
        |> Run.eval()
  """
  @spec eval(RunBuilder.t()) :: any
  def eval(%RunBuilder{} = builder) do
    run(builder).result
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
  """
  def resume(
        %RunOutcome{
          result: {:suspend, _value, k},
          run_state: run_state
        },
        input
      ) do
    Impl.do_run(k.(input), run_state)
  end

  @doc """
  Rerun a computation or builder using outputs from a previous run as the initial states.
  This is useful for replay/resume scenarios where you want to use logged states.

  ## Examples

      # With plain computation (old API)
      outcome1 = Run.run(computation, handlers, states)
      outcome2 = Run.rerun(computation, outcome1)

      # With RunBuilder (new API)
      builder = computation |> State.Handler.run(0)
      outcome1 = Run.run(builder)
      outcome2 = Run.rerun(builder, outcome1)
  """
  def rerun(%RunBuilder{} = builder, %RunOutcome{} = outcome) do
    # Update handler states from outcome
    updated_handlers =
      Enum.map(builder.handlers, fn {mod, _old_state} ->
        new_state = Map.get(outcome.outputs, mod)
        {mod, new_state}
      end)

    %{builder | handlers: updated_handlers}
    |> run()
  end

  def rerun(computation, %RunOutcome{outputs: outputs, run_state: previous_run_state}) do
    # Create new run state using outputs from previous run as initial states
    new_run_state = %{
      previous_run_state
      | states: outputs
    }

    Impl.do_run(computation, new_run_state)
  end

  @doc """
  Run a Freer or Hefty computation.

  This function automatically handles both first-order (Freer) and higher-order
  (Hefty) effect computations based on the arguments provided.

  ## Running Freer Computations (3 arguments)

  For Freer computations with only first-order effects:

      Run.run(
        computation,
        [State.Handler, Writer.Handler],
        %{State.Handler => 0, Writer.Handler => []}
      )

  ## Running Hefty Computations (4 arguments)

  For Hefty computations with higher-order effects, provide algebras:

      Run.run(
        hefty_computation,
        [Catch.Algebra, Lift.Algebra],      # Elaboration (algebras)
        [State.Handler, Error.Handler],     # Interpretation (handlers)
        %{State.Handler => 0}
      )

  ## Parameters

  - `computation` - The Freer or Hefty computation to run
  - `algebras_or_handlers` - For Freer: handlers list. For Hefty: algebras list
  - `handlers_or_initial_states` - For Freer: initial states. For Hefty: handlers list
  - `initial_states` - (Hefty only) Map of handler module to initial state

  ## Returns

  `RunOutcome.t()` containing:
  - `result` - Final value, {:error, reason}, or {:suspend, value, continuation}
  - `outputs` - Final handler states
  - `run_state` - RunState for resume operations
  """
  # Hefty: 4-arity with Hefty.Pure struct
  @spec run(Hefty.t(), [module], [module], map) :: RunOutcome.t()
  def run(%Hefty.Pure{} = hefty_tree, algebras, handlers, initial_states)
      when is_list(algebras) and is_list(handlers) and is_map(initial_states) do
    # Phase 1: Elaborate higher-order effects into first-order effects
    # Phase 2: Interpret first-order effects using existing infrastructure
    hefty_tree
    |> Elaborate.elaborate(algebras)
    |> run(handlers, initial_states)
  end

  # Hefty: 4-arity with Hefty.Impure struct
  def run(%Hefty.Impure{} = hefty_tree, algebras, handlers, initial_states)
      when is_list(algebras) and is_list(handlers) and is_map(initial_states) do
    hefty_tree
    |> Elaborate.elaborate(algebras)
    |> run(handlers, initial_states)
  end

  # Hefty: 4-arity with IHeftySendable protocol (auto-convert to Hefty)
  def run(hefty_tree, algebras, handlers, initial_states)
      when is_list(algebras) and is_list(handlers) and is_map(initial_states) do
    hefty_tree
    |> IHeftySendable.send_to_hefty()
    |> run(algebras, handlers, initial_states)
  end

  # Hefty: 3-arity (algebras, handlers, no initial_states) - default to %{}
  def run(hefty_tree, algebras, handlers)
      when is_list(algebras) and is_list(handlers) do
    run(hefty_tree, algebras, handlers, %{})
  end

  # Freer: 3-arity with initial_states
  @spec run(Freer.freer(), [module], map) :: RunOutcome.t()
  def run(computation, handlers, initial_states)
      when is_list(handlers) and is_map(initial_states) do
    # Build handler specs from handlers list and initial_states map
    handler_specs =
      Enum.map(handlers, fn handler_mod ->
        state = Map.get(initial_states, handler_mod)
        {handler_mod, {handler_mod, state}}
      end)

    run_state = RunState.new(handler_specs)
    Impl.run_with_state(computation, run_state)
  end

  # Freer: 2-arity (no initial_states) - default to %{}
  @spec run(Freer.freer(), [module]) :: RunOutcome.t()
  def run(computation, handlers) when is_list(handlers) do
    run(computation, handlers, %{})
  end

  @doc """
  Simplified run for Hefty computations with no handler state.

  Useful for quick prototyping or when handlers don't need initial state.

  ## Example

      computation = Catch.catch_hefty(
        Hefty.pure(42),
        fn _err -> Hefty.pure(0) end
      )

      outcome = Run.run_simple(
        computation,
        [Catch.Algebra, Lift.Algebra]
      )
  """
  @spec run_simple(Hefty.t(), [module]) :: RunOutcome.t()
  def run_simple(hefty_tree, algebras) do
    run(hefty_tree, algebras, [], %{})
  end
end
