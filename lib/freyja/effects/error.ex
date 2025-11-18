defmodule Freyja.Effects.Error do
  @moduledoc """
  First-order Error effect for throwing errors.

  This module provides the `throw_error` operation (first-order).

  For the higher-order `catch` operation (catching and handling errors),
  use `Freyja.Effects.Catch` which provides Hefty algebra-based
  exception handling.

  ## Example

      import Freyja.HeftyMacro

      # Throw an error
      Lift.lift(Error.throw_error("something went wrong"))

  ## See Also

  - `Freyja.Effects.Catch` - For the higher-order catch operation
  """
  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(Throw, error: nil)

  @doc """
  Throw an error, short-circuiting the computation.

  Returns a Freer effect that will fail with the given error value.
  """
  def throw_error(err), do: %Throw{error: err}
end

defmodule Freyja.Effects.Error.Handler do
  @moduledoc """
  Handler for first-order Error operations (throw only).

  This is a simple first-order effect handler. The scoped `catch` operation
  is available via `Freyja.Effects.Catch` as a Hefty algebra-based
  higher-order effect.

  ## Operations

  - `throw_error(error)` - Short-circuits computation with error

  ## See Also

  - `Freyja.Effects.Catch` - For the higher-order catch operation
  """

  alias Freyja.ErrorResult
  alias Freyja.Freer
  alias Freyja.Freer.Impure
  alias Freyja.Effects.Error
  alias Freyja.Effects.Error.Throw

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig}, _state) do
    sig == Error
  end

  @doc "Interpret an Error throw operation"
  @impl Freyja.EffectHandler
  def interpret(
        %Impure{sig: Error, data: %Throw{error: err}},
        _handler_key,
        _state,
        _run_state
      ) do
    # Throw short-circuits - discards queue
    {ErrorResult.error(err) |> Freer.return(), nil}
  end
end
