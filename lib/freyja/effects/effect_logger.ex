# define a private effect to capture interpreted effect values

defmodule Freyja.Effects.EffectLogger do
  @moduledoc """
  Signature of the EffectLogger effect
  """
  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(LogInterpretedEffectValue, value: nil)

  def log_interpreted_effect_value(v), do: %LogInterpretedEffectValue{value: v}
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
  alias Freyja.Effects.EffectLogger.ILog
  alias Freyja.Effects.EffectLogger.Log
  alias Freyja.Effects.EffectLogger.ScopedLogs
  alias Freyja.Effects.EffectLogger.EffectLogEntry
  alias Freyja.Effects.EffectLogger.LogInterpretedEffectValue
  alias Freyja.Effects.EffectLogger.StepLogEntry
  alias Freyja.Run.RunState
  alias Freyja.Run.RunOutcome

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
  defp can_replay?(sig, data, log) when is_struct(log, Log) or is_struct(log, ScopedLogs) do
    current_log = ILog.current_log(log)

    # Logger.error(
    #   "#{__MODULE__}.can_replay? #{sig}\n" <>
    #     "current_log: #{inspect(current_log, pretty: true)}"
    # )

    case current_log.queue do
      [
        %StepLogEntry{
          effects_queue: [
            %EffectLogEntry{sig: log_sig, data: log_data}
            | _
          ],
          completed?: true
        }
        | _
      ]
      when sig == log_sig and (data == log_data or log_data == nil) ->
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
      %Log{queue: [%StepLogEntry{completed?: true} | _]} ->
        # Replay mode - log has completed entries ready for replay
        # Just return the log as-is
        log

      %ScopedLogs{
        scoped_log_queue: [
          %Log{queue: [%StepLogEntry{completed?: true} | _]} | _
        ]
      } = _scoped_logs ->
        # replay mode in a nested scope
        log

      %Log{queue: [%StepLogEntry{completed?: false}]} ->
        # Scoped computation starting - create ScopedLogs with fresh Log
        ScopedLogs.new(Log.new())

      %ScopedLogs{
        scoped_log_queue: [
          %Log{queue: [%StepLogEntry{completed?: false}]}
        ]
      } = _scoped_logs ->
        # it's a nested scoped computation
        # Logger.error(
        #   "#{__MODULE__} nested scoped computation\n" <>
        #     "scoped_logs: #{inspect(scoped_logs, pretty: true)}"
        # )

        ScopedLogs.new(Log.new())

      %ScopedLogs{} = scoped_logs ->
        # Another sibling - push new empty Log
        # Logger.error(
        #   "#{__MODULE__}.push_scoped_log\n" <>
        #     "scoped_logs: #{inspect(scoped_logs, pretty: true)}"
        # )

        ScopedLogs.push_scoped_log(scoped_logs, Log.new())

      %Log{queue: []} ->
        # Empty log - either first run with no effects or replay with no effects
        # Just return as-is (will remain empty)
        log

      nil ->
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
        updated_log = ILog.log_interpreted_effect_value(log, val)
        {Impl.q_apply(q, val), updated_log}

      _ ->
        # Logger.error("#{__MODULE__}.run_logger log_or_resume")
        log_or_resume(computation, log)
    end
  end

  @impl Freyja.Freer.EffectHandler
  def scoped_error(
        _result,
        _error,
        handler_key,
        state,
        _scoped_state,
        %RunOutcome{} = scoped_run_outcome
      ) do
    scoped_log = Map.get(scoped_run_outcome.outputs, handler_key)
    prepared_scoped_log = ScopedLogs.prepare_scoped_logs_for_retrace(scoped_log)
    updated_state = ILog.set_scoped_logs(state, prepared_scoped_log)
    # Logger.error("#{__MODULE__}.scoped_error #{inspect(updated_state, pretty: true)}")
    updated_state
  end

  @impl Freyja.Freer.EffectHandler
  def finalize(
        %Pure{} = computation,
        _handler_key,
        log,
        %RunState{} = _run_state
      ) do
    finalized_log = ILog.prepare_for_retrace(log)

    # Logger.error("#{__MODULE__}.finalize #{inspect(finalized_log, pretty: true)}")
    {computation, finalized_log}
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def log_or_resume(%Impure{sig: sig, data: u, q: q} = computation, log) do
    current_log = ILog.current_log(log)

    # Logger.error(
    #   "#{__MODULE__}.log_or_resume\n" <>
    #     "computation: #{inspect(computation, pretty: true)}\n" <>
    #     "current_log: #{inspect(current_log, pretty: true)}"
    # )

    case current_log.queue do
      [] ->
        # Logger.error(
        #   "#{__MODULE__}.log_or_resume UNSEEN\n" <>
        #     "computation: #{inspect(computation, pretty: true)}\n" <>
        #     "current_log: #{inspect(current_log, pretty: true)}"
        # )

        # unseen computation - log and carry on
        updated_log = ILog.log_effect(log, computation)
        capture_k = fn v -> EffectLogger.log_interpreted_effect_value(v) end
        updated_q = q |> Freyja.Freer.Impl.q_prepend(capture_k)
        {%Freer.Impure{sig: sig, data: u, q: updated_q}, updated_log}

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
          completed?: true,
          value: value
        } = _log_entry
        | _rest
      ]
      when sig == log_entry_sig and (u == log_entry_data or log_entry_data == nil) ->
        # Logger.error(
        #   "#{__MODULE__}.log_or_resume RESUME COMPLETE\n" <>
        #     "computation: #{inspect(computation, pretty: true)}\n" <>
        #     "current_log: #{inspect(current_log, pretty: true)}"
        # )

        # NB: there may be unserializable things in the effect data - such as
        # continuations - so we allow the log_entry_data to be nil
        # TODO: maybe we should delegate matching deserialized effect
        # values to the effect modules ?
        updated_log = ILog.consume_log_entry(log)
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
          completed?: false
        } = _log_entry
        | _rest
      ]
      when sig == log_entry_sig and (u == log_entry_data or log_entry_data == nil) ->
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
          completed?: false
        } = _log_entry
        | _rest
      ] ->
        # Logger.error(
        #   "#{__MODULE__}.log_or_resume RESUME PARTIAL\n" <>
        #     "computation: #{inspect(computation, pretty: true)}\n" <>
        #     "current_log: #{inspect(current_log, pretty: true)}"
        # )

        # push the new effect to the current log entry
        # and carry on
        updated_log = ILog.push_effect(log, computation)

        # Logger.error("#{__MODULE__}.partial #{inspect(updated_log, pretty: true)}")

        {computation, updated_log}

      _ ->
        # Logger.error(
        #   "#{__MODULE__}.log_or_resume DIVERGE\n" <>
        #     "computation: #{inspect(computation, pretty: true)}\n" <>
        #     "current_log: #{inspect(current_log, pretty: true)}"
        # )

        raise ArgumentError,
          message:
            "Effect diverged from log:\n" <>
              "computation: #{inspect(computation, pretty: true)}\n" <>
              "log: #{inspect(log, pretty: true)}"
    end
  end
end
