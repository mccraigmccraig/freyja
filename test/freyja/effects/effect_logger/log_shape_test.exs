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
      cold_outcome = serialize_outcome_with_divergence(base_outcome)
      resumed_outcome = Run.resume(builder, cold_outcome, 42)
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

  defp serialize_outcome_with_divergence(outcome) do
    outcome
    |> Jason.encode!()
    |> Jason.decode!()
    |> update_in(
      ["outputs", "Elixir.Freyja.Effects.EffectLogger.Handler", "allow_divergence?"],
      fn _ -> true end
    )
  end
end
