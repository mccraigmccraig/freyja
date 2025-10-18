defmodule Freyja.Effects.State do
  @moduledoc """
  Operations in the State effect
  """
  import Freyja.Sig.DefEffectStruct

  def_effect_struct(Get)
  def_effect_struct(Put, val: nil)

  def put(v), do: %Put{val: v}
  def get, do: %Get{}
end

defmodule Freyja.Effects.State.Handler do
  @moduledoc """
  A State effect implementation using the Freer monad.
  """

  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Effects.State
  alias Freyja.Effects.State.Get
  alias Freyja.Effects.State.Put
  alias Freyja.Run.RunState

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}) do
    sig == State
  end

  @impl Freyja.EffectHandler
  def interpret(
        %Freer.Impure{sig: State, data: u, q: q} = _computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    case u do
      %Put{val: o} ->
        # return the old value, set the new
        {Impl.q_apply(q, state), o}

      %Get{} ->
        {Impl.q_apply(q, state), state}
    end
  end
end
