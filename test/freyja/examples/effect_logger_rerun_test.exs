defmodule Freyja.Examples.EffectLoggerRerunTest do
  use ExUnit.Case, async: true

  alias Freyja.Examples.EffectLoggerRerun
  alias Freyja.Run
  alias Freyja.Effects.EffectLogger.Handler, as: EffectLoggerHandler
  alias Freyja.Effects.EffectLogger.Log
  alias Freyja.Effects.EffectLogger.StepLogEntry
  alias Freyja.Effects.EffectLogger.EffectLogEntry
  alias Freyja.Effects.State
  alias Freyja.Effects.Throw

  test "rerun from serialized log" do
    buggy_builder = EffectLoggerRerun.build(:original)
    outcome = Run.run(buggy_builder)
    assert {:error, :validation_failed} = outcome.result

    # Verify original (buggy) run log structure:
    # - Two completed steps (State.Put, State.Get)
    # - One incomplete step (Throw.ThrowOp - the error)
    original_log = outcome.outputs[EffectLoggerHandler]

    assert %Log{
             stack: [],
             queue: [
               %StepLogEntry{
                 completed?: true,
                 value: 0,
                 effects_queue: [
                   %EffectLogEntry{sig: State, data: %State.Put{val: 10}}
                 ]
               },
               %StepLogEntry{
                 completed?: true,
                 value: 10,
                 effects_queue: [
                   %EffectLogEntry{sig: State, data: %State.Get{}}
                 ]
               },
               %StepLogEntry{
                 completed?: false,
                 effects_queue: [
                   %EffectLogEntry{sig: Throw, data: %Throw.ThrowOp{error: :validation_failed}}
                 ]
               }
             ],
             allow_divergence?: false
           } = original_log

    json = Jason.encode!(outcome)
    decoded = Jason.decode!(json)

    fixed_builder = EffectLoggerRerun.build(:patched)
    rerun_outcome = Run.rerun(fixed_builder, decoded)

    assert {:ok, :ok} = rerun_outcome.result

    # Verify rerun log structure:
    # - Only the two completed steps remain (State.Put, State.Get)
    # - The incomplete Throw.ThrowOp is REMOVED (regression test for stale entry bug)
    # - This is because the patched code diverged and returned :ok instead of throwing
    rerun_log = rerun_outcome.outputs[EffectLoggerHandler]

    assert %Log{
             stack: [],
             queue: [
               %StepLogEntry{
                 completed?: true,
                 value: 0,
                 effects_queue: [
                   %EffectLogEntry{sig: State, data: %State.Put{val: 10}}
                 ]
               },
               %StepLogEntry{
                 completed?: true,
                 value: 10,
                 effects_queue: [
                   %EffectLogEntry{sig: State, data: %State.Get{}}
                 ]
               }
             ],
             allow_divergence?: true
           } = rerun_log

    # Explicit check: Throw.ThrowOp should NOT be present (removed as stale entry)
    throw_count =
      rerun_log.queue
      |> Enum.flat_map(& &1.effects_queue)
      |> Enum.count(&match?(%EffectLogEntry{sig: Throw}, &1))

    assert throw_count == 0,
           "Throw.ThrowOp should not be present in rerun log, found #{throw_count}"
  end
end
