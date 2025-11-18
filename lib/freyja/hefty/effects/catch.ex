defmodule Freyja.Hefty.Effects.Catch do
  @moduledoc """
  Higher-order Catch effect for exception handling in Hefty computations.

  Based on the Catch elaboration from "Hefty Algebras" paper (Example 3.1).

  ## Overview

  The Catch effect provides exception handling for Hefty computations. It takes
  two computation parameters:
  - `try` - The computation to execute
  - `catch` - The fallback computation if an error occurs

  ## Example

      import Freyja.Hefty.Effects.Catch

      hefty do
        result <- catch_hefty(
          # Try block - might throw
          hefty do
            x <- Lift.lift(State.get())
            if x < 0 do
              Lift.lift(Error.throw_fx("negative value"))
            else
              Hefty.pure(x * 2)
            end
          end,
          # Catch block - fallback
          Hefty.pure(0)
        )

        Hefty.pure(result)
      end

  ## Elaboration

  The Catch operation is elaborated into first-order effects using the
  `Error.catch_fx` runner effect. The elaboration:

  1. Runs the try computation with error handling
  2. If successful, continues with the result
  3. If error, runs the catch computation

  The control flow decision (success vs error) is encoded as a case statement
  in the elaborated Freer computation.

  ## See Also

  - `Freyja.Hefty.Effects.Catch.Algebra` - The elaboration algebra
  - `Freyja.Effects.Error` - First-order error effects
  """

  import Freyja.Hefty.Sig.DefHeftyStruct

  # The Catch operation struct
  # Fields:
  #   type - Optional type filter (currently unused, for future extension)
  #   handler - Error handler function (error -> Hefty.t())
  def_hefty_struct(Catch, type: :any, handler: nil)

  @doc """
  Create a Catch operation with try computation and error handler function.

  ## Parameters

  - `try_comp` - Hefty computation to attempt
  - `error_handler_fn` - Function `(error -> Hefty.t())` that receives the error
    and returns a Hefty computation for recovery

  ## Returns

  A Hefty.Impure node with the Catch operation and computation forks.

  ## Example

      # Simple default value on error
      result = catch_hefty(
        hefty do
          x <- Lift.lift(computation_that_might_fail())
          Hefty.pure(x)
        end,
        fn _err -> Hefty.pure(:default_value) end
      )

      # Pattern match on error
      result = catch_hefty(
        hefty do ... end,
        fn
          :not_found -> Hefty.pure(:default)
          :timeout -> retry_computation()
          other -> Hefty.pure({:error, other})
        end
      )
  """
  def catch_hefty(try_comp, error_handler_fn) when is_function(error_handler_fn, 1) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %Catch{type: :any, handler: error_handler_fn},
      %{
        try: try_comp
        # Note: catch handler is in the Catch struct, not in psi!
      }
    )
  end
end

defmodule Freyja.Hefty.Effects.Catch.Algebra do
  @moduledoc """
  Algebra for elaborating Catch operations into first-order effects.

  Implements the elaboration from "Hefty Algebras" paper Example 3.1.

  ## Strategy

  The Catch operation is elaborated using a first-order "runner" effect pattern:

  1. Create a `RunCatching` effect that wraps the try computation
  2. The runner handler executes the computation and returns `{:ok, value}` or `{:error, err}`
  3. Use a case statement to branch on the result
  4. Call continuation with appropriate value

  ## The Runner Effect Pattern

  This is a key pattern for elaborating higher-order effects in Hefty algebras:

  **Runner Effect**: A first-order effect that a handler executes to produce an
  inspectable result (like `{:ok, value}` or `{:error, err}`). The algebra creates
  this effect during elaboration, and embeds control flow (case statements) in the
  elaborated Freer computation.

  In this case:
  - Algebra creates a `RunCatching` effect with the (already elaborated) computation
  - Algebra embeds a case statement in the elaborated Freer code to branch on results
  - `RunCatchingHandler` executes the computation and returns `{:ok, value}` or `{:error, err}`
  - The case statement's branches are plain Freer code that execute based on the result

  ## Why Use This Pattern?

  This two-phase approach (elaboration → interpretation) separates concerns:
  - **Algebras** handle structural transformations (creating effects, embedding control flow)
  - **Handlers** handle execution concerns (running computations, propagating state)
  - **Control flow** is encoded as ordinary Elixir code (case statements) in elaborated Freer computations

  Compare this to direct scoped effects (like old `Error.Catch`), where a single handler
  does everything: receives the computation, executes it, inspects the result, and decides
  what to do next. The Hefty approach is more modular - algebras compose independently
  of handlers, and complex higher-order effects can be elaborated into simpler primitives.

  ## State Propagation

  The `RunCatchingHandler` uses `ScopedOk` to propagate state changes from the
  inner computation back to the parent context. This implements non-transactional
  semantics by default - state changes persist even when errors occur.

  See `RunCatchingHandler` documentation for details on state propagation.

  ## Key Insight

  When this algebra's `elaborate/4` is called, the try and catch computations
  in `psi` are already Freer (not Hefty). The fold has elaborated them bottom-up.

  The algebra just needs to compose these Freer computations using the
  runner effect and a case statement.

  ## Example Elaboration

  Input Hefty:
      Catch.catch(
        hefty do x <- State.get(); Hefty.pure(x) end,
        Hefty.pure(0)
      )

  Elaborated Freer:
      con do
        result <- run_catching(
          con do x <- State.get(); Freer.pure(x) end  # Already Freer!
        )
        case result do
          {:ok, value} -> Freer.pure(value)
          {:error, _} -> Freer.pure(0)  # Already Freer!
        end
      end
  """

  @behaviour Freyja.Hefty.Algebra

  import Freyja.Freer.Sig.DefEffectStruct

  require Logger

  alias Freyja.Hefty.Effects.Catch.Catch, as: CatchOp
  alias Freyja.Freer

  # Simple runner effect for the prototype
  # This executes a computation and returns {:ok, value} or {:error, err}
  def_effect_struct(RunCatching, computation: nil)

  def run_catching(computation) do
    %RunCatching{computation: computation}
  end

  @impl true
  def handles?(sig) when sig == Freyja.Hefty.Effects.Catch, do: true
  def handles?(_), do: false

  @impl true
  def elaborate(%CatchOp{handler: error_handler_fn} = _op, psi, k, elaborator) do
    # Extract already-elaborated try computation (Freer)
    try_comp = Map.fetch!(psi, :try)

    # The error handler function is stored in the Catch struct
    # It's NOT in psi, so it won't be pre-elaborated
    # We'll call it dynamically when an error occurs

    # Use our own run_catching runner effect (not HeftyError.run_catching)
    # This ensures it gets handled by Catch.RunCatchingHandler which uses ScopedOk
    Freer.bind(run_catching(try_comp), fn result ->
      # Branch on the result (this case is in the Freer computation)
      case result do
        {:ok, value} ->
          # Success: continue with value
          k.(value)

        {:error, err} ->
          # Error: call handler function with error to get Hefty computation
          catch_hefty_comp = error_handler_fn.(err)
          # Elaborate the catch computation (it's Hefty, needs elaboration!)
          catch_freer_comp = elaborator.(catch_hefty_comp)
          # Then bind to continuation
          Freer.bind(catch_freer_comp, k)
      end
    end)
  end
end

defmodule Freyja.Hefty.Effects.Catch.RunCatchingHandler do
  @moduledoc """
  Handler for the RunCatching effect used by Catch.Algebra.

  Executes a computation and returns `{:ok, value}` or `{:error, err}`.

  ## State Propagation Semantics

  This handler implements **non-transactional semantics** for state propagation,
  matching the approach used in Heftia:

  - State changes in the inner computation **always propagate** to the parent context
  - This applies whether the computation succeeds, fails, or has unexpected results
  - Both `{:ok, value}` and `{:error, err}` cases preserve state changes

  This means:
  ```elixir
  catch_hefty(
    hefty do
      Lift.lift(State.put(100))
      Lift.lift(Error.throw("boom"))
    end,
    hefty do
      x <- Lift.lift(State.get())
      Hefty.pure(x)  # Will see x = 100, not initial state
    end
  )
  ```

  ## Transactional Semantics

  If you need transactional semantics (rollback state on error), use an explicit
  transactional wrapper. This keeps the Catch handler simple and makes the choice
  of transactional vs non-transactional explicit in the code.

  See: Heftia's `transactState` for reference implementation of transactional wrapper.
  """

  @behaviour Freyja.EffectHandler

  require Logger

  alias Freyja.Hefty.Effects.Catch.Algebra.RunCatching
  alias Freyja.Freer.Impure
  alias Freyja.Run
  alias Freyja.Run.RunState
  alias Freyja.Run.RunEffects
  alias Freyja.OkResult
  alias Freyja.ErrorResult

  @impl true
  def handles?(%Impure{sig: sig}, _state) do
    sig == Freyja.Hefty.Effects.Catch.Algebra
  end

  @impl true
  def interpret(
        %Impure{
          sig: Freyja.Hefty.Effects.Catch.Algebra,
          data: %RunCatching{computation: comp},
          q: q
        },
        _handler_key,
        state,
        %RunState{} = run_state
      ) do
    alias Freyja.RunOutcome

    # Run the computation
    outcome = Run.run(comp, run_state)

    # Inspect the result and wrap it in a tagged tuple
    # IMPORTANT: We use ScopedOk for ALL cases (success, error, unexpected)
    # This ensures state changes from outcome.run_state propagate to parent context
    result_value =
      case outcome.result do
        %OkResult{value: value} ->
          {:ok, value}

        %ErrorResult{error: err} ->
          {:error, err}

        other ->
          # Handle unexpected result types (e.g., SuspendResult)
          {:error, {:unexpected_result, other}}
      end

    # IMPORTANT FIX: Run.run returns outcome with run_state pointing to INPUT states,
    # but outputs pointing to FINAL states. For ScopedOk to work properly, we need
    # run_state to also have the final states. Reconstruct outcome with updated run_state.
    corrected_outcome = %RunOutcome{
      result: outcome.result,
      outputs: outcome.outputs,
      run_state: %{outcome.run_state | states: outcome.outputs}
    }

    # Return ScopedOk effect to propagate state changes
    # The value is the tagged result tuple, and run_outcome contains updated states
    # We pass through the original q - this is terminal for the scoped operation
    scoped_ok_effect = %Impure{
      sig: RunEffects,
      data: %RunEffects.ScopedOk{
        value: result_value,
        run_outcome: corrected_outcome
      },
      q: q
    }

    {scoped_ok_effect, state}
  end
end
