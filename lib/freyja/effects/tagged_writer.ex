defmodule Freyja.Effects.TaggedWriter do
  @moduledoc """
  Tagged Writer effect for maintaining multiple independent log streams.

  Unlike the regular Writer effect which maintains a single log output,
  TaggedWriter allows multiple independent log streams identified by tags.

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
  """

  import Freyja.Sig.DefEffectStruct

  def_effect_struct(TellTagged, tag: nil, val: nil)
  def_effect_struct(PeekTagged, tag: nil)
  def_effect_struct(ListenTagged, tag: nil, computation: nil)

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

  @doc """
  Execute a computation and capture the log entries written to the given tag
  during that computation.

  Returns a tuple `{result, captured_logs}` where:
  - `result` is the return value of the computation
  - `captured_logs` are the logs written to `tag` during the computation only
    (in reverse chronological order)

  This is a scoped operation - logs written inside the computation are captured
  separately from the outer accumulated logs. The captured logs are also added
  to the outer log accumulation.

  ## Example

      con [TaggedWriter] do
        tell(:audit, "before listen")

        {result, inner_logs} <- listen(:audit, fn ->
          tell(:audit, "step 1")
          tell(:audit, "step 2")
          return(42)
        end)

        # result = 42
        # inner_logs = ["step 2", "step 1"]
        # Total audit log now = ["step 2", "step 1", "before listen"]

        return({result, inner_logs})
      end
  """
  def listen(tag, computation), do: %ListenTagged{tag: tag, computation: computation}
end

defmodule Freyja.Effects.TaggedWriter.Handler do
  @moduledoc """
  Handler for the TaggedWriter effect.

  Manages multiple independent log streams in a map structure where
  keys are tags and values are lists of logged values.

  ## Handler State

  The handler state must be a map:

      %{
        tag1 => [log_entries...],
        tag2 => [log_entries...],
        ...
      }

  ## Behavior

  - `tell(tag, val)` prepends `val` to `state[tag]` list
  - `peek(tag)` returns the current log list for `tag` without modifying state
  - If tag doesn't exist, creates a new list with the single entry (tell) or returns empty list (peek)
  - Logs are accumulated in reverse chronological order (most recent first)
  """

  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Effects.TaggedWriter
  alias Freyja.Effects.TaggedWriter.TellTagged
  alias Freyja.Effects.TaggedWriter.PeekTagged
  alias Freyja.Effects.TaggedWriter.ListenTagged
  alias Freyja.Run
  alias Freyja.Run.RunEffects
  alias Freyja.Run.RunEffects.ScopedOk
  alias Freyja.Run.RunState
  alias Freyja.OkResult

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == TaggedWriter
  end

  @impl Freyja.EffectHandler
  def interpret(
        %Freer.Impure{sig: TaggedWriter, data: operation, q: q} = _computation,
        _handler_key,
        state,
        %RunState{} = run_state
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

      %ListenTagged{tag: tag, computation: inner} ->
        # Scoped operation: capture logs written to this tag during inner computation
        # Run the inner computation with current run_state
        inner_outcome = Run.run(inner, run_state)

        # Calculate what was written to this tag during the inner computation
        # by comparing inner output to current state
        current_tag_log = Map.get(state, tag, [])
        inner_tag_log = Map.get(inner_outcome.outputs.tw, tag, [])

        # The captured logs are: inner_tag_log - current_tag_log
        # Since logs are prepended, inner logs are at the front
        captured_logs = Enum.take(inner_tag_log, length(inner_tag_log) - length(current_tag_log))

        case inner_outcome.result do
          %OkResult{value: val} ->
            # Return {result, captured_logs} tuple
            result_tuple = {val, captured_logs}

            {
              %Impure{
                sig: RunEffects,
                data: %ScopedOk{
                  value: result_tuple,
                  run_outcome: inner_outcome
                },
                q: q
              },
              # State is updated by the scoped_ok handling
              state
            }
        end
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
