# define a private effect to capture interpreted effect values

defmodule Freyja.Effects.EffectLogger do
  @moduledoc """
  Signature of the EffectLogger effect
  """
  import Freyja.Sig.DefEffectStruct

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
  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.EffectLogger.ILog
  alias Freyja.Effects.EffectLogger.Log
  alias Freyja.Effects.EffectLogger.ScopedLogs
  alias Freyja.Effects.EffectLogger.EffectLogEntry
  alias Freyja.Effects.EffectLogger.LogInterpretedEffectValue
  alias Freyja.Effects.EffectLogger.StepLogEntry
  alias Freyja.Run.RunState
  alias Freyja.RunOutcome

  @behaviour Freyja.EffectHandler

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

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}) do
    if sig == EffectLogger do
      true
    else
      :observer
    end
  end

  @impl Freyja.EffectHandler
  def initialize(
        _computation,
        _handler_key,
        log,
        %RunState{} = _run_state
      ) do
    case log do
      %Log{queue: [%StepLogEntry{completed?: false}]} ->
        # Scoped computation starting - create ScopedLogs with fresh Log
        ScopedLogs.new(Log.new())

      %ScopedLogs{} = scoped_logs ->
        # Another sibling - push new empty Log
        ScopedLogs.push_scoped_log(scoped_logs, Log.new())

      nil ->
        Log.new()
    end
  end

  @impl Freyja.EffectHandler
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

      # don't touch ScopedYield effects, they reach through
      # nested scopes and will be logged in their originating
      # scope
      {Coroutine, %Coroutine.ScopedYield{value: _yield_value}} ->
        # Logger.error("#{__MODULE__} Coroutine.ScopedYield: #{inspect(yield_value, pretty: true)}")
        {computation, log}

      _ ->
        # Logger.error("#{__MODULE__}.run_logger log_or_resume")
        log_or_resume(computation, log)
    end
  end

  @impl Freyja.EffectHandler
  def scoped_ok(
        _result,
        _value,
        handler_key,
        state,
        _scoped_state,
        %RunOutcome{} = scoped_run_outcome
      ) do
    scoped_log = Map.get(scoped_run_outcome.outputs, handler_key)
    prepared_scoped_log = ScopedLogs.prepare_scoped_logs_for_retrace(scoped_log)
    updated_state = ILog.set_scoped_logs(state, prepared_scoped_log)
    # Logger.error("#{__MODULE__}.scoped_ok #{inspect(updated_state, pretty: true)}")
    updated_state
  end

  @impl Freyja.EffectHandler
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

  @impl Freyja.EffectHandler
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

  def log_or_resume(%Impure{sig: sig, data: u, q: q} = computation, log) do
    current_log = ILog.current_log(log)

    case current_log.queue do
      [] ->
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
      when sig == log_entry_sig and u == log_entry_data ->
        updated_log = ILog.consume_log_entry(log)
        {Freyja.Freer.Impl.q_apply(q, value), updated_log}

      # partially interpreted computation
      [
        %StepLogEntry{
          effects_queue: [%EffectLogEntry{} | _],
          completed?: false
        } = _log_entry
        | _rest
      ] ->
        # push the new effect tp the current log entry
        # and carry on
        updated_log = ILog.push_effect(log, computation)

        Logger.error("#{__MODULE__}.partial #{inspect(updated_log, pretty: true)}")

        {computation, updated_log}

      _ ->
        raise ArgumentError,
          message:
            "Effect diverged from log:\n" <>
              " #{inspect(log, pretty: true)}"
    end
  end
end
