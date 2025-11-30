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

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def log_or_resume(%Impure{sig: sig, data: u, q: q} = computation, %Log{} = log) do
    # Logger.error(
    #   "#{__MODULE__}.log_or_resume\n" <>
    #     "computation: #{inspect(computation, pretty: true)}\n" <>
    #     "log: #{inspect(log, pretty: true)}"
    # )

    case log.queue do
      [] ->
        # unseen computation - log and carry on
        log_new_effect(computation, log)

      # resumed fully interpreted computation - we have a value
      [
        %StepLogEntry{
          effects_queue: [
            %EffectLogEntry{
              sig: log_entry_sig,
              data: log_entry_data
            }
            | _
          ],
          completed?: completed,
          value: value
        } = _log_entry
        | _rest
      ]
      when completed in [:executed, :resumed] and sig == log_entry_sig and
             u == log_entry_data ->
        # Logger.error(
        #   "#{__MODULE__}.log_or_resume RESUME COMPLETE\n" <>
        #     "computation: #{inspect(computation, pretty: true)}\n" <>
        #     "current_log: #{inspect(current_log, pretty: true)}"
        # )

        updated_log = Log.consume_log_entry(log)
        {Freyja.Freer.Impl.q_apply(q, value), updated_log}

      # incomplete entry that matches current effect - for resuming from suspension
      [
        %StepLogEntry{
          effects_queue: [
            %EffectLogEntry{
              sig: log_entry_sig,
              data: log_entry_data
            }
            | _
          ],
          completed?: nil
        } = _log_entry
        | _rest
      ]
      when sig == log_entry_sig and u == log_entry_data ->
        # Logger.error(
        #   "#{__MODULE__}.log_or_resume RESUME INCOMPLETE\n" <>
        #     "computation: #{inspect(computation, pretty: true)}\n" <>
        #     "current_log: #{inspect(current_log, pretty: true)}"
        # )

        # This is a suspension point (e.g., Coroutine.Yield)
        # Pass through to handler - it will either suspend (first run) or resume (if state has resume_value)
        # DON'T consume the entry yet - let LogInterpretedEffectValue complete it with the actual value
        capture_k = fn v -> EffectLogger.log_interpreted_effect_value(v) end
        updated_q = q |> Freyja.Freer.Impl.q_prepend(capture_k)
        {%Freer.Impure{sig: sig, data: u, q: updated_q}, log}

      # partially interpreted computation - effect doesn't match
      [
        %StepLogEntry{
          effects_queue: [%EffectLogEntry{} | _],
          completed?: nil
        } = _log_entry
        | _rest
      ] ->
        # Logger.error(
        #   "#{__MODULE__}.log_or_resume RESUME PARTIAL\n" <>
        #     "computation: #{inspect(computation, pretty: true)}\n" <>
        #     "current_log: #{inspect(current_log, pretty: true)}"
        # )

        if log.allow_divergence? do
          log_new_effect(computation, drop_pending_entries(log))
        else
          # push the new effect to the current log entry and carry on
          updated_log = Log.push_effect(log, computation)
          {computation, updated_log}
        end

      _ ->
        # Effect diverged from log
        if log.allow_divergence? do
          log_new_effect(computation, drop_pending_entries(log))
        else
          raise ArgumentError,
            message:
              "Effect diverged from log:\n" <>
                "computation: #{inspect(computation, pretty: true)}\n" <>
                "log: #{inspect(log, pretty: true)}"
        end
    end
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
