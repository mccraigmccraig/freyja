defmodule Freyja.Effects.Reader do
  @moduledoc "Operations (Ops) for the Reader effect"
  import Freyja.Sig.DefEffectStruct

  def_effect_struct(Ask)

  def ask, do: %Ask{}
end

defmodule Freyja.Effects.Reader.Handler do
  @moduledoc "Interpreter (handler) for the Reader effect"
  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Effects.Reader
  alias Freyja.Run.RunState

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == Reader
  end

  @impl Freyja.EffectHandler
  def interpret(
        %Freer.Impure{sig: Reader, data: u, q: q} = _computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    case u do
      %Reader.Ask{} ->
        {Impl.q_apply(q, state), state}
    end
  end
end
