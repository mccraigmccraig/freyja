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

      import Freyja.HeftyMacro

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

  - `Freyja.Effects.TaggedWriter.Algebra` - Elaboration algebra for listen
  - `Freyja.Effects.Writer` - For single-stream logging
  """

  import Freyja.Freer.Sig.DefEffectStruct
  import Freyja.Hefty.Sig.DefHeftyStruct

  # First-order operations
  def_effect_struct(TellTagged, tag: nil, val: nil)
  def_effect_struct(PeekTagged, tag: nil)

  # Higher-order operations
  def_hefty_struct(Listen, [])

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

# First-order runner effect for listen
defmodule Freyja.Effects.TaggedWriter.RunListen do
  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(RunListen, computation: nil)

  def run_listen(computation) do
    %RunListen{computation: computation}
  end
end

defmodule Freyja.Effects.TaggedWriter.Algebra do
  @moduledoc """
  Algebra for elaborating TaggedWriter higher-order operations.

  Currently only handles `listen` - tell and peek are first-order effects
  that use the existing TaggedWriter handler.

  ## Listen Elaboration

  The listen operation elaborates using the runner effect pattern:

  1. Create RunListen first-order effect wrapping the inner computation
  2. RunListenHandler executes it and returns `{result, captured_logs}`
  3. Elaboration just binds the result to continuation

  The handler is responsible for:
  - Capturing log changes during computation execution
  - Returning captured logs as a map
  - Propagating state changes via ScopedOk

  This is simpler than the old scoped handler approach which had complex
  log diffing logic mixed with effect interpretation.
  """

  @behaviour Freyja.Hefty.Algebra

  alias Freyja.Effects.TaggedWriter.Listen
  import Freyja.Con
  import Freyja.Effects.TaggedWriter.RunListen, only: [run_listen: 1]

  @impl true
  def handles?(sig) when sig == Freyja.Effects.TaggedWriter, do: true
  def handles?(_), do: false

  @impl true
  def elaborate(%Listen{}, psi, k, _elaborator) do
    # Extract already-elaborated inner computation
    inner_comp = Map.fetch!(psi, :inner)

    # Use runner effect to execute and capture logs
    con do
      result_and_logs <- run_listen(inner_comp)
      k.(result_and_logs)
    end
  end
end

defmodule Freyja.Effects.TaggedWriter.RunListenHandler do
  @moduledoc """
  Handler for RunListen runner effect.

  Executes a computation and captures all log writes, returning
  `{result, captured_logs_map}`.

  ## State Propagation

  Uses ScopedOk to propagate state changes from the inner computation,
  implementing non-transactional semantics (logs and other state changes
  persist regardless of errors).
  """

  @behaviour Freyja.EffectHandler

  alias Freyja.Effects.TaggedWriter.RunListen.RunListen
  alias Freyja.Freer.Impure
  alias Freyja.Run
  alias Freyja.Run.RunState
  alias Freyja.Run.RunEffects
  alias Freyja.RunOutcome
  alias Freyja.OkResult
  alias Freyja.Effects.TaggedWriter

  @impl true
  def handles?(%Impure{sig: sig}, _state) do
    sig == Freyja.Effects.TaggedWriter.RunListen
  end

  @impl true
  def interpret(
        %Impure{
          sig: Freyja.Effects.TaggedWriter.RunListen,
          data: %RunListen{computation: comp},
          q: q
        },
        _handler_key,
        state,
        %RunState{} = run_state
      ) do
    # Run the inner computation
    outcome = Run.run(comp, run_state)

    # Get the initial state (before inner computation)
    initial_tw_state = Map.get(run_state.states, TaggedWriter.Handler, %{})

    # Get the final state (after inner computation)
    final_tw_state = Map.get(outcome.outputs, TaggedWriter.Handler, %{})

    # Calculate captured logs: what was added during the computation
    captured_logs = calculate_captured_logs(initial_tw_state, final_tw_state)

    # Extract the result value
    result_value =
      case outcome.result do
        %OkResult{value: val} -> val
        # Propagate errors as-is
        other -> other
      end

    # Return tuple of result and captured logs
    result_tuple = {result_value, captured_logs}

    # Use ScopedOk to propagate state changes
    # Fix RunOutcome to have updated run_state (same pattern as RunCatchingHandler)
    corrected_outcome = %RunOutcome{
      result: outcome.result,
      outputs: outcome.outputs,
      run_state: %{outcome.run_state | states: outcome.outputs}
    }

    scoped_ok_effect = %Impure{
      sig: RunEffects,
      data: %RunEffects.ScopedOk{
        value: result_tuple,
        run_outcome: corrected_outcome
      },
      q: q
    }

    {scoped_ok_effect, state}
  end

  # Calculate what logs were added during the computation
  # by comparing initial and final states
  defp calculate_captured_logs(initial_state, final_state) do
    final_state
    |> Enum.map(fn {tag, final_tag_log} ->
      initial_tag_log = Map.get(initial_state, tag, [])
      # New logs are at the front (prepended)
      new_logs = Enum.take(final_tag_log, length(final_tag_log) - length(initial_tag_log))
      {tag, new_logs}
    end)
    |> Enum.into(%{})
  end
end
