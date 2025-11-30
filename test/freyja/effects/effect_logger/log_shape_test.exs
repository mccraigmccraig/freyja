defmodule Freyja.Effects.EffectLogger.LogShapeTest do
  use ExUnit.Case, async: true

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.{Coroutine, EffectLogger, State}
  alias Freyja.Effects.EffectLogger.Log
  alias Freyja.Run

  describe "rerun log shape" do
    test "prefix is preserved and new steps remain single-effect" do
      base_comp =
        con [State] do
          _ <- put(0)
          value <- get()
          return(value)
        end

      diverged_comp =
        con [State] do
          _ <- put(0)
          value <- get()
          _ <- put(value + 1)
          final <- get()
          return(final)
        end

      {base_outcome, base_log} = run_state_computation(base_comp)
      base_entries = base_log.queue

      builder =
        diverged_comp
        |> EffectLogger.Handler.run(clone(base_log))
        |> State.Handler.run(0)

      rerun_outcome = Run.rerun(builder, base_outcome)
      rerun_log = Log.prepare_for_retrace(rerun_outcome.outputs[EffectLogger.Handler])
      rerun_entries = rerun_log.queue

      assert_prefix_equal(base_entries, rerun_entries)

      extra_entries = Enum.drop(rerun_entries, length(base_entries))
      assert extra_entries != []
      assert_single_effect_steps(extra_entries)
    end
  end

  describe "resume log shape" do
    test "prefix is preserved and resumed steps remain single-effect (with divergence allowed)" do
      # This test verifies that when resuming with DIFFERENT code (diverged_comp),
      # the log preserves the prefix and new steps are single-effect.
      # This requires explicitly allowing divergence since the code differs.
      base_comp =
        con [Coroutine, State] do
          _ <- State.put(0)
          value <- Coroutine.yield(:wait)
          _ <- State.put(value)
          return(value)
        end

      diverged_comp =
        con [Coroutine, State] do
          _ <- State.put(0)
          value <- Coroutine.yield(:wait)
          _ <- State.put(value)
          final <- State.get()
          _ <- State.put(final + 1)
          return(final + 1)
        end

      {base_outcome, base_log} = run_coroutine_with_log(base_comp)
      base_entries = base_log.queue

      builder =
        diverged_comp
        |> EffectLogger.Handler.run(Log.new())
        |> Coroutine.Handler.run(nil)
        |> State.Handler.run(0)

      # Enable divergence since we're resuming with different code
      cold_outcome = serialize_outcome(base_outcome)
      resumed_outcome = Run.resume(builder, cold_outcome, 42, allow_divergence: true)
      resumed_log = Log.prepare_for_retrace(resumed_outcome.outputs[EffectLogger.Handler])
      resumed_entries = resumed_log.queue

      assert_prefix_equal(base_entries, resumed_entries)

      extra_entries = Enum.drop(resumed_entries, length(base_entries))
      assert extra_entries != []
      assert_single_effect_steps(extra_entries)
    end
  end

  defp run_state_computation(computation) do
    outcome =
      computation
      |> EffectLogger.Handler.run(Log.new())
      |> State.Handler.run(0)
      |> Run.run()

    log = Log.prepare_for_retrace(outcome.outputs[EffectLogger.Handler])
    {outcome, log}
  end

  defp run_coroutine_with_log(computation) do
    outcome =
      computation
      |> EffectLogger.Handler.run(Log.new())
      |> Coroutine.Handler.run()
      |> State.Handler.run(0)
      |> Run.run()

    log = Log.prepare_for_retrace(outcome.outputs[EffectLogger.Handler])
    {outcome, log}
  end

  defp assert_prefix_equal(expected_entries, actual_entries) do
    completed_prefix = Enum.take_while(expected_entries, & &1.completed?)
    prefix_length = length(completed_prefix)

    expected_signatures = Enum.map(completed_prefix, &step_signature/1)

    actual_signatures =
      actual_entries
      |> Enum.take(prefix_length)
      |> Enum.map(&step_signature/1)

    assert actual_signatures == expected_signatures
  end

  defp assert_single_effect_steps(entries) do
    assert Enum.all?(entries, fn entry -> length(entry.effects_queue) == 1 end),
           "expected new steps to contain a single effect each, got: #{inspect(entries, pretty: true)}"
  end

  defp step_signature(step) do
    step.effects_queue
    |> Enum.map(fn eff -> {eff.sig, eff.data} end)
  end

  defp clone(term), do: term |> :erlang.term_to_binary() |> :erlang.binary_to_term()

  defp serialize_outcome(outcome), do: outcome |> Jason.encode!() |> Jason.decode!()

  describe "divergent intermediate effects" do
    alias Freyja.Effects.EffectLogger.Handler
    alias Freyja.Effects.EffectLogger.StepLogEntry
    alias Freyja.Effects.EffectLogger.EffectLogEntry
    alias Freyja.Freer.Impure

    test "divergent effect within incomplete step is pushed as intermediate effect, not new step" do
      # Construct a log with an incomplete step that has multiple logged effects
      # This simulates a step that was in progress with intermediate effects [A, B, C]
      incomplete_step = %StepLogEntry{
        effects_stack: [],
        effects_queue: [
          %EffectLogEntry{sig: State, data: %State.Put{val: 100}},
          %EffectLogEntry{sig: State, data: %State.Get{}},
          %EffectLogEntry{sig: State, data: %State.Put{val: 200}}
        ],
        completed?: nil,
        value: nil
      }

      log = %Log{
        stack: [],
        queue: [incomplete_step],
        allow_divergence?: true
      }

      # Create a divergent effect - State.Put{val: 999} doesn't match head (Put{val: 100})
      # or next (Get{})
      divergent_computation = %Impure{
        sig: State,
        data: %State.Put{val: 999},
        q: [&Freyja.Freer.pure/1]
      }

      # Call log_or_resume directly
      {result_computation, result_log} = Handler.log_or_resume(divergent_computation, log)

      # The result should still be an Impure (effect passed through)
      assert %Impure{sig: State, data: %State.Put{val: 999}} = result_computation

      # The log should still have one step (not a new step created)
      assert length(result_log.queue) == 1

      # The step should have the divergent effect pushed as intermediate
      [updated_step] = result_log.queue

      # The original head effect should now be on the stack
      assert [%EffectLogEntry{sig: State, data: %State.Put{val: 100}}] =
               updated_step.effects_stack

      # The divergent effect should now be at the head of the queue
      assert [%EffectLogEntry{sig: State, data: %State.Put{val: 999}}] =
               updated_step.effects_queue

      # Step should still be incomplete
      assert updated_step.completed? == nil
    end

    test "divergent effect on completed step starts new step" do
      # Construct a log with a completed step
      completed_step = %StepLogEntry{
        effects_stack: [],
        effects_queue: [
          %EffectLogEntry{sig: State, data: %State.Put{val: 100}}
        ],
        completed?: :executed,
        value: 0
      }

      log = %Log{
        stack: [],
        queue: [completed_step],
        allow_divergence?: true
      }

      # Create a divergent effect that doesn't match the completed step
      divergent_computation = %Impure{
        sig: State,
        data: %State.Put{val: 999},
        q: [&Freyja.Freer.pure/1]
      }

      # Call log_or_resume directly
      {result_computation, result_log} = Handler.log_or_resume(divergent_computation, log)

      # The result should be an Impure with capture continuation prepended
      assert %Impure{sig: State, data: %State.Put{val: 999}} = result_computation

      # The log queue should be empty (pending entries dropped) and a new step started
      # Actually, log_new_effect adds to queue, so we should have one new step
      assert length(result_log.queue) == 1

      [new_step] = result_log.queue

      # The new step should have the divergent effect
      assert [%EffectLogEntry{sig: State, data: %State.Put{val: 999}}] = new_step.effects_queue

      # New step should be incomplete (just started)
      assert new_step.completed? == nil
    end

    test "without allow_divergence, divergent effect raises error" do
      incomplete_step = %StepLogEntry{
        effects_stack: [],
        effects_queue: [
          %EffectLogEntry{sig: State, data: %State.Put{val: 100}},
          %EffectLogEntry{sig: State, data: %State.Get{}}
        ],
        completed?: nil,
        value: nil
      }

      log = %Log{
        stack: [],
        queue: [incomplete_step],
        allow_divergence?: false
      }

      divergent_computation = %Impure{
        sig: State,
        data: %State.Put{val: 999},
        q: [&Freyja.Freer.pure/1]
      }

      assert_raise ArgumentError, ~r/Effect diverged from log/, fn ->
        Handler.log_or_resume(divergent_computation, log)
      end
    end
  end
end
