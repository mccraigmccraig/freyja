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

  import Freyja.Sig.DefHeftyStruct

  # The Catch operation struct
  # Fields: type - Optional type filter (currently unused, for future extension)
  def_hefty_struct(Catch, type: :any)

  @doc """
  Create a Catch operation with try and catch computations.

  ## Parameters

  - `try_comp` - Hefty computation to attempt
  - `catch_comp` - Hefty computation to run if try fails

  ## Returns

  A Hefty.Impure node with the Catch operation and two forks.

  ## Example

      try_comp = hefty do
        x <- Lift.lift(computation_that_might_fail())
        Hefty.pure(x)
      end

      catch_comp = Hefty.pure(:default_value)

      result = catch_hefty(try_comp, catch_comp)
  """
  def catch_hefty(try_comp, catch_comp) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %Catch{type: :any},
      %{
        try: try_comp,
        catch: catch_comp
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

  This is a key pattern for elaborating higher-order effects in Heftia:

  **Runner Effect**: A first-order effect that takes a computation as **data** (not
  as a higher-order parameter) and executes it, returning an inspectable result.

  In this case:
  - `RunCatching` struct contains the computation as data
  - `RunCatchingHandler` executes it and returns `{:ok, value}` or `{:error, err}`
  - The elaborated code has a case statement that branches on the result

  This pattern separates concerns:
  - **Elaboration** (structural transformation): Creates the runner effect and case statement
  - **Interpretation** (execution): Handler runs the computation and propagates state
  - **Control flow**: Encoded as ordinary case statements in the elaborated Freer code

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

  import Freyja.Sig.DefEffectStruct

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
  def elaborate(%CatchOp{} = _op, psi, k, _elaborator) do
    # Extract already-elaborated Freer computations
    try_comp = Map.fetch!(psi, :try)
    catch_comp = Map.fetch!(psi, :catch)

    # Use our own run_catching runner effect (not HeftyError.run_catching)
    # This ensures it gets handled by Catch.RunCatchingHandler which uses ScopedOk
    Freer.bind(run_catching(try_comp), fn result ->
      # Branch on the result (this case is in the Freer computation)
      case result do
        {:ok, value} ->
          # Success: continue with value
          k.(value)

        {:error, _err} ->
          # Error: run catch computation, then continue
          Freer.bind(catch_comp, k)
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
