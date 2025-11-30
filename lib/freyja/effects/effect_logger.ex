# define a private effect to capture interpreted effect values

defmodule Freyja.Effects.EffectLogger do
  @moduledoc """
  Signature of the EffectLogger effect
  """
  import Freyja.Freer.Sig.DefEffectStruct
  alias Freyja.Freer

  def_effect_struct(LogInterpretedEffectValue, value: nil)

  def log_interpreted_effect_value(v),
    do: %LogInterpretedEffectValue{value: v} |> Freer.send_effect()
end

defmodule Freyja.Effects.EffectLogger.Handler do
  @moduledoc """
  Handler for the EffectLogger effect
  """
  require Logger

  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Pure
  alias Freyja.Freer.Impure
  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.EffectLogger.Log
  alias Freyja.Effects.EffectLogger.EffectLogEntry
  alias Freyja.Effects.EffectLogger.LogInterpretedEffectValue
  alias Freyja.Effects.EffectLogger.StepLogEntry
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  # logger captures effects in log-queue/log-stack, and avoids repeat work
  #
  # - if the effect matches the head of the queue,
  #   - and theres a value, then
  #     - put the log-entry on the stack, and
  #     - handle the effect withe the value
  #   - if there's no value, we
  #     - leave the log-entry at the head of the queue
  #     - put a handler at the head of the chain to capture
  #       the value
  # - if the effect doesn't match the head of the queue
  #   - return an error effect - uncontrolled side-effects
  # - if the queue is empty,
  #   - add a log-entry to the head with the effect
  #   - put a handler at the head of the chain to capture the value
  #
  #
  # - if the effect is pure ??
  #   - reverse the stack and set it as the queue
  #
  # - how do logs compose ?

  @impl Freyja.Freer.EffectHandler
  def handles?(%Impure{sig: sig, data: u, q: _q}, state) do
    cond do
      # Always handle our own EffectLogger effects
      sig == EffectLogger ->
        true

      # Check if we can replay this effect from the log
      can_replay?(sig, u, state) ->
        true

      # Otherwise, we're just observing
      true ->
        # Logger.error("#{__MODULE__}.observer")
        :observer
    end
  end

  # Check if we have a logged value to replay for this effect
  defp can_replay?(sig, data, %Log{} = log) do
    # Logger.error(
    #   "#{__MODULE__}.can_replay? #{sig}\n" <>
    #     "log: #{inspect(log, pretty: true)}"
    # )

    case log.queue do
      [
        %StepLogEntry{
          effects_queue: [
            %EffectLogEntry{sig: log_sig, data: log_data}
            | _
          ],
          completed?: completed
        }
        | _
      ]
      when completed in [:executed, :resumed] and sig == log_sig and data == log_data ->
        true

      _ ->
        false
    end
  end

  defp can_replay?(_sig, _data, _state), do: false

  @impl Freyja.Freer.EffectHandler
  def initialize(
        _computation,
        _handler_key,
        log,
        %RunState{} = _run_state
      ) do
    case log do
      %Log{stack: [_ | _]} = log ->
        # Log has entries in stack (from a suspended computation that didn't finalize)
        # Prepare for retrace to move stack entries to queue for replay
        Log.prepare_for_retrace(log)

      %Log{} ->
        # Return existing log as-is (replay mode with empty stack, or empty log)
        log

      nil ->
        # Create new log
        Log.new()
    end
  end

  @impl Freyja.Freer.EffectHandler
  def interpret(
        %Impure{sig: eff, data: u, q: q} = computation,
        _handler_key,
        log,
        %RunState{} = _run_state
      ) do
    # Logger.error("#{__MODULE__} interpret: #{inspect(computation, pretty: true)}")

    case {eff, u} do
      {EffectLogger, %LogInterpretedEffectValue{value: val}} ->
        # Logger.error("#{__MODULE__}.run_logger handling")
        # capturing the value of an executed effect
        updated_log = Log.log_interpreted_effect_value(log, val)
        {Impl.q_apply(q, val), updated_log}

      _ ->
        # Logger.error("#{__MODULE__}.run_logger log_or_resume")
        log_or_resume(computation, log)
    end
  end

  @impl Freyja.Freer.EffectHandler
  def finalize(
        %Pure{} = computation,
        _handler_key,
        log,
        %RunState{} = _run_state
      ) do
    finalized_log = Log.prepare_for_retrace(log)

    # Logger.error("#{__MODULE__}.finalize #{inspect(finalized_log, pretty: true)}")
    {computation, finalized_log}
  end

  @doc """
  Core logic for logging effects or resuming from a log.

  Handles the following cases:
  1. Empty queue - new computation, start logging a new step
  2. Completed step, effect matches - replay from log
  3. Incomplete step, effect matches head - continue execution (first run or resume)
  4. Incomplete step, effect matches next in queue - within-step replay
  5. Incomplete step, single effect, no match - within-step first run (new intermediate effect)
  6. Divergence - effect doesn't match log, handle based on allow_divergence?
  """
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def log_or_resume(%Impure{sig: sig, data: data} = computation, %Log{} = log) do
    case log.queue do
      [] ->
        # Case 1: Empty queue - new computation, start new step
        log_new_step(computation, log)

      [%StepLogEntry{} = step | _rest] ->
        cond do
          # Case 2: Completed step, effect matches head - replay from log
          StepLogEntry.completed?(step) and StepLogEntry.effect_matches_head?(step, sig, data) ->
            replay_from_log(computation, log)

          # Case 3: Incomplete step, effect matches head - continue execution
          # This happens when resuming from suspension (e.g., after Coroutine.Yield)
          not StepLogEntry.completed?(step) and StepLogEntry.effect_matches_head?(step, sig, data) ->
            continue_execution(computation, log)

          # Case 4: Incomplete step, effect matches next in queue - within-step replay
          # We're replaying within a step and need to advance to the next logged effect
          not StepLogEntry.completed?(step) and StepLogEntry.effect_matches_next?(step, sig, data) ->
            advance_within_step(computation, log)

          # Case 5: Incomplete step, single effect in queue, no match - within-step first run
          # A handler is sending a new intermediate effect before returning a value
          not StepLogEntry.completed?(step) and StepLogEntry.single_effect_in_queue?(step) ->
            push_within_step(computation, log)

          # Case 6: Divergence - effect doesn't match the log
          true ->
            handle_divergence(computation, log)
        end
    end
  end

  # Case 1: Start logging a new step (empty queue)
  defp log_new_step(%Impure{} = computation, %Log{} = log) do
    log_new_effect(computation, log)
  end

  # Case 2: Replay a completed step from the log
  defp replay_from_log(%Impure{q: q} = _computation, %Log{} = log) do
    [%StepLogEntry{value: value} | _] = log.queue
    updated_log = Log.consume_log_entry(log)
    {Freyja.Freer.Impl.q_apply(q, value), updated_log}
  end

  # Case 3: Continue execution of an incomplete step
  # The effect matches what we logged, so add capture continuation and let it execute
  defp continue_execution(%Impure{sig: sig, data: data, q: q} = _computation, %Log{} = log) do
    capture_k = fn v -> EffectLogger.log_interpreted_effect_value(v) end
    updated_q = q |> Freyja.Freer.Impl.q_prepend(capture_k)
    {%Freer.Impure{sig: sig, data: data, q: updated_q}, log}
  end

  # Case 4: Advance within a step during replay
  # Push current effect to stack, advance to next in queue
  defp advance_within_step(%Impure{sig: sig, data: data, q: q} = computation, %Log{} = log) do
    updated_log = Log.push_effect(log, computation)
    # Continue with the effect - it will be handled by other handlers
    {%Freer.Impure{sig: sig, data: data, q: q}, updated_log}
  end

  # Case 5: Push a new intermediate effect within a step (first run)
  defp push_within_step(%Impure{sig: sig, data: data, q: q} = computation, %Log{} = log) do
    updated_log = Log.push_effect(log, computation)
    # Continue with the effect - it will be handled by other handlers
    {%Freer.Impure{sig: sig, data: data, q: q}, updated_log}
  end

  # Case 6: Handle divergence from the log
  defp handle_divergence(%Impure{sig: sig, data: data} = computation, %Log{} = log) do
    [%StepLogEntry{} = step | _] = log.queue

    if log.allow_divergence? do
      if StepLogEntry.completed?(step) do
        # Completed step doesn't match - drop pending entries and start a new step
        log_new_effect(computation, drop_pending_entries(log))
      else
        # Incomplete step - this is a new intermediate effect within the current step
        # Drop the stale effects from the queue and push this as a new intermediate effect
        cleared_log = clear_step_effects_queue(log)
        push_within_step(computation, cleared_log)
      end
    else
      error_context =
        if StepLogEntry.completed?(step) do
          "Completed step exists but effect doesn't match.\n" <>
            "This usually means the computation took a different path than the logged run."
        else
          "Incomplete step exists but effect doesn't match head or next.\n" <>
            "This usually means a handler is producing different intermediate effects."
        end

      raise ArgumentError,
        message:
          "Effect diverged from log:\n\n" <>
            "#{error_context}\n\n" <>
            "Effect: sig=#{inspect(sig)}, data=#{inspect(data, pretty: true)}\n\n" <>
            "Log step: #{inspect(step, pretty: true)}\n\n" <>
            "To allow divergence (e.g., for rerun with patched code), use Log.allow_divergence/1"
    end
  end

  # Clear the effects_queue of the current step, keeping only the head effect
  # Used when diverging within a step - we keep the step but discard stale logged effects
  defp clear_step_effects_queue(
         %Log{queue: [%StepLogEntry{effects_queue: [head | _]} = step | rest]} = log
       ) do
    cleared_step = %{step | effects_queue: [head]}
    %{log | queue: [cleared_step | rest]}
  end

  @doc """
  Add this handler to a computation or builder pipeline.

  ## Examples

      # Start new pipeline with fresh log
      computation |> EffectLogger.Handler.run(Log.new())

      # Resume with existing log
      builder |> EffectLogger.Handler.run(resume_log)

      # For error resume with divergence allowed
      builder |> EffectLogger.Handler.run(Log.for_error_resume(log))
  """
  def run(computation_or_builder, initial_state) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end

  defp log_new_effect(%Impure{} = computation, %Log{} = log) do
    %Impure{sig: sig, data: u, q: q} = computation
    updated_log = Log.log_effect(log, computation)
    capture_k = fn v -> EffectLogger.log_interpreted_effect_value(v) end
    updated_q = q |> Freyja.Freer.Impl.q_prepend(capture_k)
    {%Freer.Impure{sig: sig, data: u, q: updated_q}, updated_log}
  end

  defp drop_pending_entries(%Log{} = log), do: %{log | queue: []}
end
