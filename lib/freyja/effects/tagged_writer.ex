defmodule Freyja.Effects.TaggedWriter do
  @moduledoc """
  Tagged Writer effect for maintaining multiple independent log streams.

  Unlike the regular Writer effect which maintains a single log output,
  TaggedWriter allows multiple independent log streams identified by tags.

  This module provides ONLY first-order operations (`tell` and `peek`).

  For the higher-order `listen` operation (capturing logs during a computation),
  use `Freyja.Hefty.Effects.HeftyTaggedWriter` which provides Hefty algebra-based
  listen functionality.

  ## Example

      con [TaggedWriter] do
        # Write to different tagged log streams
        tell(:audit, "user logged in")
        tell(:debug, "processing request")
        tell(:metrics, %{duration: 100})

        return(:ok)
      end

  ## Handler Setup

  The handler state must be a map where keys are tags and values are the
  log list for each tag:

      Run.with_handlers(
        tw: {TaggedWriter.Handler, %{
          audit: [],
          debug: [],
          metrics: []
        }}
      )

  ## Tags

  Tags can be any term (atoms, strings, numbers, tuples, etc.), but atoms
  are recommended for clarity and performance.

  ## Log Order

  Like the regular Writer effect, logs are accumulated in reverse chronological
  order (most recent first) for each tag independently.

  ## See Also

  - `Freyja.Hefty.Effects.HeftyTaggedWriter` - For the higher-order `listen` operation
  - `Freyja.Effects.Writer` - For single-stream logging
  """

  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(TellTagged, tag: nil, val: nil)
  def_effect_struct(PeekTagged, tag: nil)

  @doc """
  Write a value to the log stream associated with the given tag.

  The value is prepended to the log list for `tag`.
  """
  def tell(tag, val), do: %TellTagged{tag: tag, val: val}

  @doc """
  Query the current accumulated log for the given tag.

  Returns the log list for `tag` in reverse chronological order (most recent first).
  Returns an empty list if the tag has no logged values yet.
  """
  def peek(tag), do: %PeekTagged{tag: tag}
end

defmodule Freyja.Effects.TaggedWriter.Handler do
  @moduledoc """
  Handler for first-order TaggedWriter operations (tell and peek).

  This is now a simple first-order effect handler. The scoped `listen` operation
  has been removed and is available via `Freyja.Hefty.Effects.HeftyTaggedWriter`
  as a Hefty algebra-based higher-order effect.

  Manages multiple independent log streams in a map structure where
  keys are tags and values are lists of logged values.

  ## Handler State

  The handler state must be a map:

      %{
        tag1 => [log_entries...],
        tag2 => [log_entries...],
        ...
      }

  ## Operations

  - `tell(tag, val)` - Prepends `val` to `state[tag]` list
  - `peek(tag)` - Returns the current log list for `tag` without modifying state

  ## Behavior

  - If tag doesn't exist, creates a new list with the single entry (tell) or returns empty list (peek)
  - Logs are accumulated in reverse chronological order (most recent first)

  ## See Also

  - `Freyja.Hefty.Effects.HeftyTaggedWriter` - For the higher-order `listen` operation
  """

  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Effects.TaggedWriter
  alias Freyja.Effects.TaggedWriter.{TellTagged, PeekTagged}
  alias Freyja.Run.RunState

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == TaggedWriter
  end

  @impl Freyja.EffectHandler
  def interpret(
        %Impure{sig: TaggedWriter, data: operation, q: q} = _computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    unless is_map(state) do
      raise ArgumentError,
            "TaggedWriter.Handler state must be a map, got: #{inspect(state)}"
    end

    case operation do
      %TellTagged{tag: tag, val: val} ->
        # Get existing log list for this tag, or start with empty list
        tag_log = Map.get(state, tag, [])
        # Prepend new value (reverse chronological order)
        updated_tag_log = [val | tag_log]
        # Update state with new log
        updated_state = Map.put(state, tag, updated_tag_log)
        {Impl.q_apply(q, updated_tag_log), updated_state}

      %PeekTagged{tag: tag} ->
        # Return current log for this tag without modifying state
        current_log = Map.get(state, tag, [])
        {Impl.q_apply(q, current_log), state}
    end
  end

  @impl Freyja.EffectHandler
  def finalize(
        %Pure{} = computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    # Don't reverse - keep state = output for replay compatibility
    # Each tag's output will be in reverse chronological order (most recent first)
    {computation, state || %{}}
  end
end
