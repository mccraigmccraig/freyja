defmodule Freyja.Examples.EffectLoggerResumeTest do
  use ExUnit.Case, async: true

  alias Freyja.Examples.EffectLoggerResume
  alias Freyja.Run
  alias Freyja.Effects.EffectLogger.Handler, as: EffectLoggerHandler
  alias Freyja.Effects.EffectLogger.Log
  alias Freyja.Effects.EffectLogger.StepLogEntry
  alias Freyja.Effects.EffectLogger.EffectLogEntry
  alias Freyja.Effects.State
  alias Freyja.Effects.Coroutine

  test "resume suspended computation from serialized outcome" do
    builder = EffectLoggerResume.build()
    outcome = Run.run(builder)

    assert {:suspend, "resume_me", _} = outcome.result

    # Verify initial run log structure:
    # - Stack has one completed step (State.Put before yield)
    #   Note: effects are in effects_stack before prepare_for_retrace moves them to effects_queue
    # - Queue has one incomplete step (Coroutine.Yield - suspended)
    initial_log = outcome.outputs[EffectLoggerHandler]

    assert %Log{
             stack: [
               %StepLogEntry{
                 completed?: true,
                 value: 0,
                 effects_stack: [
                   %EffectLogEntry{sig: State, data: %State.Put{val: 5}}
                 ],
                 effects_queue: []
               }
             ],
             queue: [
               %StepLogEntry{
                 completed?: false,
                 effects_stack: [],
                 effects_queue: [
                   %EffectLogEntry{sig: Coroutine, data: %Coroutine.Yield{value: "resume_me"}}
                 ]
               }
             ],
             allow_divergence?: false
           } = initial_log

    json = Jason.encode!(outcome)
    decoded = Jason.decode!(json)

    resumed = Run.resume(builder, decoded, 42)

    assert {:done, 42} = resumed.result

    # Verify resumed log structure:
    # - Stack is empty (all moved to queue via prepare_for_retrace)
    # - Queue has three completed steps in order:
    #   1. State.Put{val: 5} (replayed from initial run)
    #   2. Coroutine.Yield (now completed with resume value 42)
    #   3. State.Put{val: 42} (new work after resume)
    # - State.Put{val: 5} should appear exactly ONCE (regression test for duplication bug)
    resumed_log = resumed.outputs[EffectLoggerHandler]

    assert %Log{
             stack: [],
             queue: [
               %StepLogEntry{
                 completed?: true,
                 value: 0,
                 effects_queue: [
                   %EffectLogEntry{sig: State, data: %State.Put{val: 5}}
                 ]
               },
               %StepLogEntry{
                 completed?: true,
                 value: 42,
                 effects_queue: [
                   %EffectLogEntry{sig: Coroutine, data: %Coroutine.Yield{value: "resume_me"}}
                 ]
               },
               %StepLogEntry{
                 completed?: true,
                 value: 5,
                 effects_queue: [
                   %EffectLogEntry{sig: State, data: %State.Put{val: 42}}
                 ]
               }
             ],
             allow_divergence?: true
           } = resumed_log

    # Explicit check: State.Put{val: 5} appears exactly once (not duplicated)
    state_put_5_count =
      resumed_log.queue
      |> Enum.flat_map(& &1.effects_queue)
      |> Enum.count(&match?(%EffectLogEntry{data: %State.Put{val: 5}}, &1))

    assert state_put_5_count == 1,
           "State.Put{val: 5} should appear exactly once, found #{state_put_5_count}"
  end
end
