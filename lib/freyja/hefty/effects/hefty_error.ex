defmodule Freyja.Hefty.Effects.HeftyError do
  @moduledoc """
  Error effect designed for Hefty algebras.

  This is a clean implementation of error handling for use with Hefty computations.

  ## Operations

  - `throw_error/1` - First-order: Throw an error

  ## Example

      import Freyja.Hefty.Effects.HeftyError

      # Throw an error
      Lift.lift(throw_error("something went wrong"))

  ## Note

  Error handling (catch) is provided by the `Freyja.Effects.Catch` higher-order
  effect, which elaborates using a runner effect. See `Catch.catch_hefty/2` for usage.
  """

  import Freyja.Freer.Sig.DefEffectStruct

  # Throw an error - returns a Freer effect that will fail with the given error value
  def_effect_struct(ThrowError, error: nil)

  def throw_error(err), do: %ThrowError{error: err}
end

defmodule Freyja.Hefty.Effects.HeftyError.Handler do
  @moduledoc """
  Handler for HeftyError effect.

  Interprets:
  - ThrowError: Returns ErrorResult, short-circuiting the computation

  ## Note

  This handler only handles `throw_error`. Error catching is handled by the
  `Catch` higher-order effect's elaboration, which uses its own runner effect
  (`Catch.Algebra.RunCatching`) to execute computations and propagate state changes.
  """

  @behaviour Freyja.EffectHandler

  alias Freyja.Hefty.Effects.HeftyError
  alias Freyja.Hefty.Effects.HeftyError.ThrowError
  alias Freyja.Freer.Impure
  alias Freyja.Run.RunState
  alias Freyja.ErrorResult

  @impl true
  def handles?(%Impure{sig: sig}, _state) do
    sig == HeftyError
  end

  @impl true
  def interpret(
        %Impure{sig: HeftyError, data: %ThrowError{error: err}, q: _q},
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    # Throw: return ErrorResult (short-circuits queue)
    {ErrorResult.error(err) |> Freyja.Freer.return(), state}
  end
end
