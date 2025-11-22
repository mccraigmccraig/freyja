defmodule Freyja.Effects.Writer do
  @moduledoc "Operations (Ops) for the Writer effect"
  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(Tell, val: nil)

  def tell(v), do: %Tell{val: v}
end

defmodule Freyja.Effects.Writer.Handler do
  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Effects.Writer
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  @impl true
  def default_initial_state(), do: []

  @impl true
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == Writer
  end

  @impl Freyja.Freer.EffectHandler
  def interpret(
        %Freer.Impure{sig: Writer, data: u, q: q} = _computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    case u do
      %Writer.Tell{val: o} ->
        updated_state = [o | state || []]
        {Impl.q_apply(q, updated_state), updated_state}
    end
  end

  @impl Freyja.Freer.EffectHandler
  def finalize(
        %Pure{} = computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    # Don't reverse - keep state = output for replay compatibility
    # Output will be in reverse chronological order (most recent first)
    {computation, state || []}
  end
end
