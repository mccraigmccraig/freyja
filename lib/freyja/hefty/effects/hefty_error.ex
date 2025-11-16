defmodule Freyja.Hefty.Effects.HeftyError do
  @moduledoc """
  Error effect designed for Hefty algebras (prototype/future version).

  This is a clean implementation of error handling without the legacy
  ScopedOk/ScopedError system. Once Hefty algebras are proven, this will
  replace the old Error effect.

  ## Operations

  - `throw_error/1` - First-order: Throw an error
  - `run_catching/1` - First-order runner: Execute computation, return tagged result

  ## Example

      import Freyja.Hefty.Effects.HeftyError

      # Throw an error
      Lift.lift(throw_error("something went wrong"))

      # Run with error handling (used by Catch elaboration)
      con do
        result <- run_catching(risky_computation)
        case result do
          {:ok, value} -> Freer.pure(value)
          {:error, err} -> Freer.pure(:fallback)
        end
      end
  """

  import Freyja.Sig.DefEffectStruct

  # Throw an error - returns a Freer effect that will fail with the given error value
  def_effect_struct(ThrowError, error: nil)

  # Run a computation and catch any errors - returns {:ok, value} or {:error, err}
  # This is the "runner" effect used by Catch.Algebra elaboration
  def_effect_struct(RunCatching, computation: nil)

  def throw_error(err), do: %ThrowError{error: err}
  def run_catching(computation), do: %RunCatching{computation: computation}
end

defmodule Freyja.Hefty.Effects.HeftyError.Handler do
  @moduledoc """
  Handler for HeftyError effect (clean Hefty-compatible version).

  Interprets:
  - ThrowError: Returns ErrorResult
  - RunCatching: Executes computation, returns {:ok, value} or {:error, err}
  """

  @behaviour Freyja.EffectHandler

  alias Freyja.Hefty.Effects.HeftyError
  alias Freyja.Hefty.Effects.HeftyError.ThrowError
  alias Freyja.Hefty.Effects.HeftyError.RunCatching
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Impl
  alias Freyja.Run
  alias Freyja.Run.RunState
  alias Freyja.OkResult
  alias Freyja.ErrorResult

  @impl true
  def handles?(%Impure{sig: sig}, _state) do
    sig == HeftyError
  end

  @impl true
  def interpret(
        %Impure{sig: HeftyError, data: operation, q: q},
        _handler_key,
        state,
        %RunState{} = run_state
      ) do
    case operation do
      %ThrowError{error: err} ->
        # Throw: return ErrorResult (short-circuits queue)
        {ErrorResult.error(err) |> Freyja.Freer.return(), state}

      %RunCatching{computation: comp} ->
        # RunCatching: execute computation and return tagged result
        outcome = Run.run(comp, run_state)

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
end
