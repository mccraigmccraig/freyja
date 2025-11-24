defmodule Freyja.Effects.TaggedWriter do
  @moduledoc """
  Tagged Writer effect for maintaining multiple independent log streams.

  Unlike the regular Writer effect which maintains a single log output,
  TaggedWriter allows multiple independent log streams identified by tags.

  ## Operations

  - `tell(tag, val)` - First-order: Write to tagged log (uses existing effect)
  - `peek(tag)` - First-order: Query tagged log (uses existing effect)
  - `listen(computation)` - Higher-order: Capture logs from computation (Hefty algebra)

  ## Example (First-order)

      con [TaggedWriter] do
        # Write to different tagged log streams
        tell(:audit, "user logged in")
        tell(:debug, "processing request")
        tell(:metrics, %{duration: 100})

        return(:ok)
      end

  ## Example (Higher-order with listen)

      import Freyja.Hefty.HeftyBlock

      hefty do
        tell(:audit, "before listen")

        {result, logs} <- TaggedWriter.listen(hefty do
          tell(:audit, "step 1")
          tell(:debug, "debug info")
          return(42)
        end)

        # logs = %{audit: ["step 1"], debug: ["debug info"]}
        return({result, logs})
      end

  ## Handler Setup

  The handler state must be a map where keys are tags and values are the
  log list for each tag:

      RunState.new(
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

  - `Freyja.Effects.TaggedWriter.Algebra` - Elaboration algebra for listen
  - `Freyja.Effects.Writer` - For single-stream logging
  """

  import Freyja.Freer.Sig.DefEffectStruct
  import Freyja.Hefty.Sig.DefHeftyStruct
  alias Freyja.Freer

  # First-order operations
  def_effect_struct(TellTagged, tag: nil, val: nil)
  def_effect_struct(PeekTagged, tag: nil)
  def_effect_struct(PeekAll, [])

  # Higher-order operations
  def_hefty_struct(Listen, [])

  @doc """
  Write a value to the log stream associated with the given tag.

  The value is prepended to the log list for `tag`.
  """
  @spec tell(atom, any) :: Freer.t()
  def tell(tag, val), do: %TellTagged{tag: tag, val: val} |> Freer.send_effect()

  @doc """
  Query the current accumulated log for the given tag.

  Returns the log list for `tag` in reverse chronological order (most recent first).
  Returns an empty list if the tag has no logged values yet.
  """
  @spec peek(atom) :: Freer.t()
  def peek(tag), do: %PeekTagged{tag: tag} |> Freer.send_effect()

  @doc """
  Query the current accumulated logs for all tags.

  Returns a map of `%{tag => [logs]}` for all tags that have been written to.
  Each tag's log list is in reverse chronological order (most recent first).
  """
  @spec peek_all :: Freer.t()
  def peek_all(), do: %PeekAll{} |> Freer.send_effect()

  @doc """
  Execute a computation and capture all logs written during it.

  Returns `{result, captured_logs}` where captured_logs is a map of
  `%{tag => [logs]}` for all tags written to during the computation.

  ## Parameters

  - `computation` - Hefty computation to execute with log capture

  ## Example

      TaggedWriter.listen(hefty do
        tell(:audit, "event 1")
        tell(:audit, "event 2")
        return(:ok)
      end)
      # Returns: {:ok, %{audit: ["event 2", "event 1"]}}
  """
  def listen(computation) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %Listen{},
      %{inner: computation}
    )
  end
end

defmodule Freyja.Effects.TaggedWriter.Handler do
  @moduledoc """
  Handler for first-order TaggedWriter operations (tell and peek).

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

  - `Freyja.Effects.TaggedWriter.Algebra` - For the higher-order `listen` operation
  """

  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Effects.TaggedWriter
  alias Freyja.Effects.TaggedWriter.{TellTagged, PeekTagged, PeekAll}
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  @impl true
  def default_initial_state(), do: %{}

  @impl true
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == TaggedWriter
  end

  @impl Freyja.Freer.EffectHandler
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

      %PeekAll{} ->
        # Return current logs for all tags without modifying state
        {Impl.q_apply(q, state || %{}), state}
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
    # Each tag's output will be in reverse chronological order (most recent first)
    {computation, state || %{}}
  end

  @doc """
  Add this handler to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      computation |> TaggedWriter.Handler.run(%{})

      # With initial values per tag
      builder |> TaggedWriter.Handler.run(%{log: ["initial"], audit: []})

      # Use default empty map
      builder |> TaggedWriter.Handler.run()
  """
  def run(computation_or_builder, initial_state \\ :__default__) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end
end

defmodule Freyja.Effects.TaggedWriter.Algebra do
  @moduledoc """
  Algebra for elaborating TaggedWriter higher-order operations.

  Currently only handles `listen` - tell and peek are first-order effects
  that use the existing TaggedWriter handler.

  ## Listen Elaboration (Interposition-based)

  The listen operation uses interposition with PeekAll to capture logs:

  1. Use PeekAll to get initial log state before the computation
  2. Run the inner computation (Tell operations execute normally)
  3. Use PeekAll to get final log state after the computation
  4. Calculate the diff to determine captured logs
  5. Return {result, captured_logs}

  This approach:
  - No nested Run.run() call
  - No ScopedOk needed
  - Works correctly with suspensions (interposition preserves structure)
  - All effects stay at the same level

  The key insight: We don't need to intercept Tell operations, just query
  the state before/after using PeekAll to calculate what was added.
  """

  @behaviour Freyja.Hefty.Algebra

  alias Freyja.Effects.TaggedWriter
  alias Freyja.Effects.TaggedWriter.Listen
  import Freyja.Freer.FreerBlock

  @impl true
  def handles?(sig) when sig == Freyja.Effects.TaggedWriter, do: true
  def handles?(_), do: false

  @impl true
  def elaborate(%Listen{}, psi, k, _elaborator) do
    # Extract already-elaborated inner computation
    inner_comp = Map.fetch!(psi, :inner)

    # Use PeekAll to capture logs before and after
    con do
      # Get initial logs
      initial_logs <- TaggedWriter.peek_all()

      # Run the inner computation
      result <- inner_comp

      # Get final logs
      final_logs <- TaggedWriter.peek_all()

      # Calculate captured logs (what was added during inner_comp)
      captured = calculate_captured_logs(initial_logs, final_logs)

      # Return tuple and continue
      k.({result, captured})
    end
  end

  # Calculate what logs were added by comparing initial and final states
  defp calculate_captured_logs(initial, final) do
    final
    |> Enum.map(fn {tag, final_tag_log} ->
      initial_tag_log = Map.get(initial, tag, [])
      # New logs are at the front (prepended)
      new_logs = Enum.take(final_tag_log, length(final_tag_log) - length(initial_tag_log))
      {tag, new_logs}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Add this algebra to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      hefty_computation |> TaggedWriter.Algebra.run()

      # Add to existing pipeline
      builder |> TaggedWriter.Algebra.run()
  """
  def run(computation_or_builder) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, nil)
  end
end
