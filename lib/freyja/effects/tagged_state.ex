defmodule Freyja.Effects.TaggedState do
  @moduledoc """
  Tagged State effect for managing multiple independent state values.

  Unlike the regular State effect which manages a single state value,
  TaggedState allows multiple independent state values identified by tags.

  ## Example

      con [TaggedState] do
        # Get and put different tagged states
        cache_val <- TaggedState.get(:cache)
        config_val <- TaggedState.get(:config)

        TaggedState.put(:cache, new_cache_val)
        TaggedState.put(:session_id, 123)

        return(:ok)
      end

  ## Handler Setup

  The handler state must be a map where keys are tags and values are the
  state for each tag:

      RunState.new(
        ts: {TaggedState.Handler, %{
          cache: %{},
          config: %{host: "localhost"},
          session_id: nil
        }}
      )

  ## Tags

  Tags can be any term (atoms, strings, numbers, tuples, etc.), but atoms
  are recommended for clarity and performance.
  """

  import Freyja.Freer.Sig.DefEffectStruct
  alias Freyja.Freer

  def_effect_struct(GetTagged, tag: nil)
  def_effect_struct(PutTagged, tag: nil, val: nil)
  def_effect_struct(UpdateTagged, tag: nil, f: nil)

  @doc """
  Get the state value for the given tag.

  Returns the current state associated with `tag`.
  """
  @spec get(atom) :: Freer.t()
  def get(tag), do: %GetTagged{tag: tag} |> Freer.send_effect()

  @doc """
  Put a new state value for the given tag.

  Sets the state associated with `tag` to `val`.
  Returns the previous state value for that tag.
  """
  @spec put(atom, any) :: Freer.t()
  def put(tag, val), do: %PutTagged{tag: tag, val: val} |> Freer.send_effect()

  @doc """
  Update the state value for the given tag using a function.

  Applies function `f` to the current state associated with `tag`,
  and sets the result as the new state for that tag.
  Returns the previous state value for that tag.

  ## Example

      con [TaggedState] do
        # Increment a counter
        old_count <- TaggedState.update(:counter, fn c -> c + 1 end)
        return(old_count)
      end
  """
  @spec update(atom, (any -> any)) :: Freer.t()
  def update(tag, f), do: %UpdateTagged{tag: tag, f: f} |> Freer.send_effect()
end

defmodule Freyja.Effects.TaggedState.Handler do
  @moduledoc """
  Handler for the TaggedState effect.

  Manages multiple independent state values in a map structure where
  keys are tags and values are the state for each tag.

  ## Handler State

  The handler state must be a map:

      %{
        tag1 => state1,
        tag2 => state2,
        ...
      }

  ## Behavior

  - `get(tag)` returns the value at `state[tag]`, or `nil` if not present
  - `put(tag, val)` sets `state[tag] = val` and returns the old value
  """

  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Effects.TaggedState
  alias Freyja.Effects.TaggedState.GetTagged
  alias Freyja.Effects.TaggedState.PutTagged
  alias Freyja.Effects.TaggedState.UpdateTagged
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  @impl Freyja.Freer.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == TaggedState
  end

  @impl Freyja.Freer.EffectHandler
  def interpret(
        %Freer.Impure{sig: TaggedState, data: operation, q: q} = _computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    unless is_map(state) do
      raise ArgumentError,
            "TaggedState.Handler state must be a map, got: #{inspect(state)}"
    end

    case operation do
      %GetTagged{tag: tag} ->
        value = Map.get(state, tag)
        {Impl.q_apply(q, value), state}

      %PutTagged{tag: tag, val: new_val} ->
        old_val = Map.get(state, tag)
        new_state = Map.put(state, tag, new_val)
        {Impl.q_apply(q, old_val), new_state}

      %UpdateTagged{tag: tag, f: f} ->
        old_val = Map.get(state, tag)
        new_val = f.(old_val)
        new_state = Map.put(state, tag, new_val)
        {Impl.q_apply(q, old_val), new_state}
    end
  end

  @doc """
  Add this handler to a computation or builder pipeline.

  ## Examples

      # Start new pipeline with tagged states
      computation |> TaggedState.Handler.run(%{tag1: 0, tag2: 10})

      # Add to existing pipeline
      builder |> TaggedState.Handler.run(%{user: %{}, session: %{}})
  """
  def run(computation_or_builder, initial_state) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end
end
