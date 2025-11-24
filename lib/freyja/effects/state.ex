defmodule Freyja.Effects.State do
  @moduledoc """
  Operations in the State effect
  """
  import Freyja.Freer.Sig.DefEffectStruct
  alias Freyja.Freer

  def_effect_struct(Get)
  def_effect_struct(Put, val: nil)
  def_effect_struct(Update, f: nil)

  @spec put(any) :: Freer.t()
  def put(v), do: %Put{val: v} |> Freer.send_effect()

  @spec get :: Freer.t()
  def get, do: %Get{} |> Freer.send_effect()

  @spec update((any -> any)) :: Freer.t()
  def update(f), do: %Update{f: f} |> Freer.send_effect()
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
  alias Freyja.Effects.State.Update
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  @impl Freyja.Freer.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == State
  end

  @impl Freyja.Freer.EffectHandler
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

      %Update{f: f} ->
        # return the old value, update state with the function
        {Impl.q_apply(q, state), f.(state)}

      %Get{} ->
        {Impl.q_apply(q, state), state}
    end
  end

  @doc """
  Add this handler to a computation or builder pipeline.

  ## Examples

      # Start new pipeline with initial state
      computation |> State.Handler.run(0)

      # Add to existing pipeline
      builder |> State.Handler.run(initial_state)
  """
  def run(computation_or_builder, initial_state) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end
end
