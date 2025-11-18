defmodule Freyja.Effects.Error do
  @moduledoc """
  First-order Error effect for throwing errors.

  This module provides ONLY the `throw_fx` operation (first-order).

  For the higher-order `catch` operation (catching and handling errors),
  use `Freyja.Hefty.Effects.Catch` which provides Hefty algebra-based
  exception handling.

  ## See Also

  - `Freyja.Hefty.Effects.Catch` - For the higher-order catch operation
  - `Freyja.Hefty.Effects.HeftyError` - For Hefty-compatible error operations
  """
  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(Throw, error: nil)

  def throw_fx(err), do: %Throw{error: err}
end

defmodule Freyja.Effects.Error.Handler do
  @moduledoc """
  Handler for first-order Error operations (throw only).

  This is now a simple first-order effect handler. The scoped `catch_fx` operation
  has been removed and is available via `Freyja.Hefty.Effects.Catch` as a Hefty
  algebra-based higher-order effect.

  ## Operations

  - `throw_fx(error)` - Short-circuits computation with error

  ## See Also

  - `Freyja.Hefty.Effects.Catch` - For the higher-order catch operation
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
