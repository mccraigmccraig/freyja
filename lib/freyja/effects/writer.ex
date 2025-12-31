defmodule Freyja.Effects.Writer do
  @moduledoc "Operations (Ops) for the Writer effect"
  import Freyja.Freer.Sig.DefEffectStruct
  alias Freyja.Freer

  def_effect_struct(Tell, val: nil)

  @spec tell(any) :: Freer.t()
  def tell(v), do: %Tell{val: v} |> Freer.send_effect()
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
  def default_initial_state, do: []

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

  @doc """
  Add this handler to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      computation |> Writer.Handler.run([])

      # Add to existing pipeline
      builder |> Writer.Handler.run(["initial"])

      # Use default empty list
      builder |> Writer.Handler.run()
  """
  def run(computation_or_builder, initial_state \\ :__default__) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end
end
