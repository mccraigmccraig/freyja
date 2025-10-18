defmodule Freyja.Effects.Reader.Constructors do
  @moduledoc "Constructors for the Reader effect"

  @doc "Get the current environment value"
  def ask(), do: :ask
end

defmodule Freyja.Effects.Reader do
  @moduledoc "Operations (Ops) for the Reader effect"
  use Freyja.Freer.Ops, constructors: Freyja.Effects.Reader.Constructors
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
  def handles?(%Impure{sig: sig, data: _data, q: _q}) do
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
      :ask ->
        {Impl.q_apply(q, state), state}
    end
  end
end
