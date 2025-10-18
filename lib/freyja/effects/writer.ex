defmodule Freyja.Effects.Writer.Constructors do
  @moduledoc "Constructors for the Writer effect"

  @doc "Output a value to the writer's log"
  def tell(o), do: {:tell, o}
end

defmodule Freyja.Effects.Writer do
  @moduledoc "Operations (Ops) for the Writer effect"
  use Freyja.Freer.Ops, constructors: Freyja.Effects.Writer.Constructors
end

defmodule Freyja.Effects.Writer.Handler do
  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Effects.Writer
  alias Freyja.Run.RunState

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}) do
    sig == Writer
  end

  @impl Freyja.EffectHandler
  def interpret(
        %Freer.Impure{sig: Writer, data: u, q: q} = _computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    case u do
      {:tell, o} ->
        updated_state = [o | state || []]
        {Impl.q_apply(q, updated_state), updated_state}
    end
  end

  @impl Freyja.EffectHandler
  def finalize(
        %Pure{} = computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    {computation, Enum.reverse(state || [])}
  end
end
