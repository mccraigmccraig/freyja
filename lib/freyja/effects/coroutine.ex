# Operations for the coroutine effect
defmodule Freyja.Effects.Coroutine do
  @moduledoc """
  The Coroutine effect signature
  """
  import Freyja.Sig.DefEffectStruct

  def_effect_struct(Yield, value: nil)
  def_effect_struct(ScopedYield, value: nil)

  def yield(value), do: %Yield{value: value}
  def scoped_yield(value), do: %ScopedYield{value: value}
end

defmodule Freyja.Effects.Coroutine.Handler do
  @moduledoc """
  A coroutine effect implementation using the Freer monad.
  Provides yield operation that suspends computation and returns a value to the caller.
  The computation can be resumed by providing a value that becomes the result of the yield operation.

  Based on the Haskell implementation in Control.Monad.Freer.Coroutine.
  """

  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.Coroutine.Yield
  alias Freyja.Effects.Coroutine.ScopedYield
  alias Freyja.Run.RunState
  alias Freyja.SuspendResult

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == Coroutine
  end

  @doc """
  Interpret a coroutine and report its status.
  """
  @impl Freyja.EffectHandler
  def interpret(
        %Impure{sig: Coroutine, data: u, q: q} = _computation,
        _handler_key,
        _state,
        %RunState{}
      ) do
    case u do
      # shoft-circuit - discard queue - it lives on in k
      %Yield{value: val} ->
        k = fn v -> Impl.q_apply(q, v) end
        {SuspendResult.yield(val, k) |> Freer.return(), nil}

      # identical behaviour to Yield, but it marks the effect
      # as resulting from a scoped execution
      %ScopedYield{value: val} ->
        k = fn v -> Impl.q_apply(q, v) end
        {SuspendResult.yield(val, k) |> Freer.return(), nil}
    end
  end
end
