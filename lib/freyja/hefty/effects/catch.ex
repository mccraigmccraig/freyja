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

  import Freyja.Sig.DefEffectStruct

  # The Catch operation struct
  # Fields: type - Optional type filter (currently unused, for future extension)
  def_effect_struct(Catch, type: :any)

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

  1. Use `Error.catch_fx/1` to run the try computation with error handling
  2. The runner returns `{:ok, value}` or `{:error, err}`
  3. Use a case statement to branch on the result
  4. Call continuation with appropriate value

  ## Key Insight

  When this algebra's `elaborate/4` is called, the try and catch computations
  in `psi` are already Freer (not Hefty). The fold has elaborated them bottom-up.

  The algebra just needs to compose these Freer computations using the
  Error.catch_fx runner and a case statement.

  ## Example Elaboration

  Input Hefty:
      Catch.catch(
        hefty do x <- State.get(); Hefty.pure(x) end,
        Hefty.pure(0)
      )

  Elaborated Freer:
      con do
        result <- Error.catch_fx(
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

  alias Freyja.Hefty.Effects.Catch.Catch, as: CatchOp
  alias Freyja.Hefty.Effects.HeftyError
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
  def elaborate(%CatchOp{}, psi, k, _elaborator) do
    # Extract already-elaborated Freer computations
    try_comp = Map.fetch!(psi, :try)
    catch_comp = Map.fetch!(psi, :catch)

    # Use HeftyError.run_catching runner effect
    # It executes try_comp and returns {:ok, value} or {:error, err}
    Freer.bind(HeftyError.run_catching(try_comp), fn result ->
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

  This handler is specific to the Catch elaboration and works with HeftyError
  to provide clean error handling without the legacy scoped system.
  """

  @behaviour Freyja.EffectHandler

  alias Freyja.Hefty.Effects.Catch.Algebra.RunCatching
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Impl
  alias Freyja.Run
  alias Freyja.Run.RunState
  alias Freyja.OkResult
  alias Freyja.ErrorResult

  @impl true
  def handles?(%Impure{sig: sig}, _state) do
    sig == Freyja.Hefty.Effects.Catch.Algebra
  end

  @impl true
  def interpret(
        %Impure{sig: Freyja.Hefty.Effects.Catch.Algebra, data: %RunCatching{computation: comp}, q: q},
        _handler_key,
        state,
        %RunState{} = run_state
      ) do
    # Run the computation
    outcome = Run.run(comp, run_state)

    # Inspect the result and return tagged tuple
    result =
      case outcome.result do
        %OkResult{value: value} ->
          {:ok, value}

        %ErrorResult{error: err} ->
          {:error, err}

        other ->
          # Handle unexpected result types (e.g., SuspendResult)
          {:error, {:unexpected_result, other}}
      end

    # Return the tagged result
    {Impl.q_apply(q, result), state}
  end
end
