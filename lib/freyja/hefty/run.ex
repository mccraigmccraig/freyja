defmodule Freyja.Hefty.Run do
  @moduledoc """
  Execute Hefty computations using the two-phase elaboration-interpretation pipeline.

  Based on "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects"
  (Poulsen & van der Rest, POPL 2023).

  ## Overview

  Hefty.Run orchestrates the complete execution of Hefty computations:

      Hefty H A --elaborate--> Freer Δ A --interpret--> Result

  **Phase 1: Elaboration**
  - Transform higher-order effects into first-order effects
  - Apply algebras bottom-up using catamorphism
  - Result: Freer computation with only first-order effects

  **Phase 2: Interpretation**
  - Execute first-order effects using existing Freyja.Run infrastructure
  - Apply effect handlers
  - Result: RunOutcome with final value and handler states

  ## Key Insight: Separation of Concerns

  This architecture cleanly separates:
  - **Structure transformation** (elaboration) - what effects mean
  - **Effect execution** (interpretation) - how effects run

  Higher-order effects (Catch, Local, FxMap) don't need special runtime handling.
  They're elaborated away before interpretation begins.

  ## Example

      # Define computation with higher-order effect
      computation = Catch.catch_hefty(
        hefty do
          x <- Lift.lift(State.get())
          if x < 0, do: Lift.lift(Error.throw_error("negative"))
          Hefty.pure(x * 2)
        end,
        fn _err -> Hefty.pure(0) end
      )

      # Run with algebras and handlers
      outcome = Hefty.Run.run(
        computation,
        [Catch.Algebra, Lift.Algebra],      # Elaboration phase
        [State.Handler, Error.Handler],     # Interpretation phase
        %{State => 5}
      )

      # Result
      outcome.result.value  # => 10 (since 5 >= 0)

      # With negative state
      outcome2 = Hefty.Run.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, Error.Handler],
        %{State => -5}
      )

      outcome2.result.value  # => 0 (caught error, ran fallback)

  ## Reusing Existing Infrastructure

  The key design decision: **Phase 2 reuses ALL existing Freyja.Run infrastructure**.

  - Effect handlers don't change
  - RunState, RunOutcome unchanged
  - All existing first-order effects work immediately
  - No special suspension handling needed

  Only the elaboration phase is new.

  ## See Also

  - `Freyja.Hefty.Elaborate` - Elaboration catamorphism
  - `Freyja.Hefty.Algebra` - Algebra behavior
  - `Freyja.Run` - First-order effect interpreter (phase 2)
  """

  alias Freyja.Hefty
  alias Freyja.Hefty.Elaborate
  alias Freyja.Run

  @doc """
  Run a Hefty computation through elaboration then interpretation.

  ## Parameters

  - `hefty_tree` - The Hefty computation to execute
  - `algebras` - List of algebra modules for elaboration (phase 1)
  - `handlers` - List of effect handler modules for interpretation (phase 2)
  - `initial_states` - Map of initial handler states (default: %{})

  ## Returns

  `RunOutcome.t()` - Same structure as Freyja.Run.run/2:
  - `result` - OkResult, ErrorResult, or SuspendResult
  - `states` - Final handler states
  - `outputs` - Handler outputs

  ## Phases

  ### Phase 1: Elaboration
  Transforms the Hefty tree into a Freer computation:
  - Applies algebras bottom-up
  - Higher-order operations become first-order effects
  - Returns Freer.t()

  ### Phase 2: Interpretation
  Executes the Freer computation:
  - Uses existing Freyja.Run infrastructure
  - Applies effect handlers
  - Returns RunOutcome

  ## Examples

      # Simple computation with State
      computation = Lift.lift(State.get())

      outcome = Hefty.Run.run(
        computation,
        [Lift.Algebra],
        [State.Handler],
        %{State => 42}
      )

      outcome.result.value  # => 42

      # With Catch and error handling
      computation = Catch.catch_hefty(
        Lift.lift(Error.throw_error("error")),
        fn _err -> Hefty.pure(:recovered) end
      )

      outcome = Hefty.Run.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [Error.Handler]
      )

      outcome.result.value  # => :recovered

      # Multiple effects composing
      computation = hefty do
        x <- Lift.lift(State.get())
        y <- Catch.catch_hefty(
          Lift.lift(computation_that_might_fail(x)),
          fn _err -> Hefty.pure(0) end
        )
        Lift.lift(State.put(x + y))
        Hefty.pure(y)
      end

  ## Error Handling

  Raises `ArgumentError` if:
  - No algebra handles a higher-order effect signature
  - An algebra module doesn't implement the behavior correctly

  Runtime errors from handlers are returned in ErrorResult as usual.
  """
  @spec run(Hefty.t(), [module], [module], map) :: Run.RunOutcome.t()
  def run(hefty_tree, algebras, handlers, initial_states \\ %{}) do
    # Phase 1: Elaborate higher-order effects into first-order effects
    freer_computation = Elaborate.elaborate(hefty_tree, algebras)

    # Phase 2: Interpret first-order effects using existing infrastructure
    # Build handler specs from handlers list and initial_states map
    handler_specs = Enum.map(handlers, fn handler_mod ->
      state = Map.get(initial_states, handler_mod)
      {handler_mod, {handler_mod, state}}
    end)

    run_state = Run.with_handlers(handler_specs)
    Run.run(freer_computation, run_state)
  end

  @doc """
  Simplified run for computations with no handler state.

  Useful for quick prototyping or when handlers don't need initial state.

  ## Example

      computation = Catch.catch_hefty(
        Hefty.pure(42),
        fn _err -> Hefty.pure(0) end
      )

      outcome = Hefty.Run.run_simple(
        computation,
        [Catch.Algebra, Lift.Algebra]
      )
  """
  @spec run_simple(Hefty.t(), [module]) :: Run.RunOutcome.t()
  def run_simple(hefty_tree, algebras) do
    run(hefty_tree, algebras, [], %{})
  end
end
