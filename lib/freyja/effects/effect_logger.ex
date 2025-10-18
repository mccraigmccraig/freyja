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
  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.EffectLogger.Log
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
        # it's a scoped computation - start a new log, stashing the
        # parent for later
        Log.new(log)

      nil ->
        Log.new()
    end
  end

  @impl Freyja.EffectHandler
  def interpret(
        %Impure{sig: eff, data: u, q: q} = computation,
        _handler_key,
        %Log{} = log,
        %RunState{} = _run_state
      ) do
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

  @impl Freyja.EffectHandler
  def scoped_return(
        _result,
        _computation,
        handler_key,
        state,
        _scoped_state,
        %RunOutcome{} = run_outcome
      ) do
    scoped_log = Map.get(run_outcome.outputs, handler_key)
    Log.set_scoped_log(state, scoped_log)
  end

  @impl Freyja.EffectHandler
  def finalize(
        %Pure{} = computation,
        _handler_key,
        log,
        %RunState{} = _run_state
      ) do
    # finalized_log = Log.prepare_for_retrace(log)

    # Logger.error("#{__MODULE__}.finalize #{inspect(finalized_log, pretty: true)}")
    {computation, log}
  end

  def log_or_resume(%Impure{sig: sig, data: u, q: q} = computation, %Log{} = log) do
    case log.queue do
      [] ->
        # unseen computation - log and carry on
        updated_log = Log.log_effect(log, computation)
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
        updated_log = Log.consume_log_entry(log)
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
        updated_log = Log.push_effect(log, computation)

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
