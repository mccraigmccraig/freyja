defmodule Freyja.EffectLoggerErrorTest do
  use ExUnit.Case

  require Logger

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.EffectLogger.{Log, StepLogEntry}
  alias Freyja.Effects.Throw
  alias Freyja.Effects.State
  alias Freyja.Run
  alias Freyja.Run.RunOutcome

  describe "EffectLogger with error resume" do
    test "error happens again - uses logged value" do
      computation =
        con [State] do
          _ <- put(10)
          x <- get()
          # This will error
          if x == 10 do
            Throw.throw_error(:validation_failed)
          else
            return(:ok)
          end
        end

      # First run - errors
      outcome1 =
        computation
        |> EffectLogger.Handler.run(Log.new())
        |> Throw.Handler.run()
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: {:error, :validation_failed}} = outcome1
      log = outcome1.outputs[EffectLogger.Handler]
      state = outcome1.outputs[State.Handler]

      # Serialize and prepare for resume
      json_log = Jason.encode!(log)
      resume_log = json_log |> Jason.decode!() |> Log.from_json() |> Log.for_error_resume()

      # Resume - error should happen again (effect matches, uses logged value)
      outcome2 =
        computation
        |> EffectLogger.Handler.run(resume_log)
        |> Throw.Handler.run()
        |> State.Handler.run(state)
        |> Run.run()

      # Should get the same error
      assert %RunOutcome{result: {:error, :validation_failed}} = outcome2
    end

    test "bug fixed - effect diverges, continues past error" do
      # Create a module attribute to track which version of validation to use
      # We'll simulate a bug fix by changing the computation logic

      make_computation = fn should_error ->
        con [State] do
          _ <- put(10)
          _x <- get()
          # Simulate bug fix: old version errors, new version succeeds
          if should_error do
            Throw.throw_error(:validation_failed)
          else
            return(:ok)
          end
        end
      end

      # First run - errors with old logic
      outcome1 =
        make_computation.(true)
        |> EffectLogger.Handler.run(Log.new())
        |> Throw.Handler.run()
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: {:error, :validation_failed}} = outcome1
      log = outcome1.outputs[EffectLogger.Handler]
      state = outcome1.outputs[State.Handler]

      # Serialize and prepare for resume with divergence allowed
      json_log = Jason.encode!(log)
      resume_log = json_log |> Jason.decode!() |> Log.from_json() |> Log.for_error_resume()

      # Resume with fixed logic - should diverge at error point and continue
      outcome2 =
        make_computation.(false)
        |> EffectLogger.Handler.run(resume_log)
        |> Throw.Handler.run()
        |> State.Handler.run(state)
        |> Run.run()

      # Should succeed now (bug fixed)
      assert %RunOutcome{result: {:ok, :ok}} = outcome2
    end

    test "hot rerun allows divergence for debugging" do
      make_computation = fn should_error ->
        con [State] do
          _ <- put(10)
          _x <- get()

          if should_error do
            Throw.throw_error(:validation_failed)
          else
            return(:ok)
          end
        end
      end

      outcome1 =
        make_computation.(true)
        |> EffectLogger.Handler.run(Log.new())
        |> Throw.Handler.run()
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: {:error, :validation_failed}} = outcome1

      builder =
        make_computation.(false)
        |> EffectLogger.Handler.run(Log.new())
        |> Throw.Handler.run()
        |> State.Handler.run(outcome1.outputs[State.Handler])

      outcome2 = Run.rerun(builder, outcome1)

      assert %RunOutcome{result: {:ok, :ok}} = outcome2
    end

    test "serialized rerun sets divergence flag for debugging" do
      make_computation = fn should_error ->
        con [State] do
          _ <- put(10)
          _x <- get()

          if should_error do
            Throw.throw_error(:validation_failed)
          else
            return(:ok)
          end
        end
      end

      outcome1 =
        make_computation.(true)
        |> EffectLogger.Handler.run(Log.new())
        |> Throw.Handler.run()
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: {:error, :validation_failed}} = outcome1

      builder =
        make_computation.(false)
        |> EffectLogger.Handler.run(Log.new())
        |> Throw.Handler.run()
        |> State.Handler.run(0)

      serialized = outcome1 |> Jason.encode!() |> Jason.decode!()
      outcome2 = Run.rerun(builder, serialized)

      assert %RunOutcome{result: {:ok, :ok}} = outcome2
      assert outcome2.outputs[State.Handler] == outcome1.outputs[State.Handler]
    end

    test "divergence without flag - raises error" do
      make_computation = fn final_put_value ->
        con [State] do
          _ <- put(10)
          _ <- get()
          # Last effect diverges - different put value
          _ <- put(final_put_value)
          return(:done)
        end
      end

      # First run with put(20)
      outcome1 =
        make_computation.(20)
        |> EffectLogger.Handler.run(Log.new())
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: :done} = outcome1
      log = outcome1.outputs[EffectLogger.Handler]
      state = outcome1.outputs[State.Handler]

      # Prepare resume WITHOUT allow_final_divergence
      json_log = Jason.encode!(log)
      resume_log = json_log |> Jason.decode!() |> Log.from_json()
      # Don't call for_error_resume - flag stays false

      # Resume with different final put value - should raise on divergence
      assert_raise ArgumentError, ~r/Effect diverged from log/, fn ->
        make_computation.(999)
        |> EffectLogger.Handler.run(resume_log)
        |> State.Handler.run(state)
        |> Run.run()
      end
    end

    test "divergence mid-log - allowed with flag and rest of log is fresh" do
      make_computation = fn value_at_step2 ->
        con [State] do
          _ <- put(10)
          # Step 2 - will diverge
          _ <- put(value_at_step2)
          _ <- put(30)
          x <- get()
          return(x)
        end
      end

      # First run
      outcome1 =
        make_computation.(20)
        |> EffectLogger.Handler.run(Log.new())
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: 30} = outcome1
      log = outcome1.outputs[EffectLogger.Handler]

      # Prepare for resume with divergence allowed
      json_log = Jason.encode!(log)
      resume_log = json_log |> Jason.decode!() |> Log.from_json() |> Log.for_error_resume()

      # Resume with different value at step 2 - should diverge gracefully
      outcome2 =
        make_computation.(999)
        |> EffectLogger.Handler.run(resume_log)
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: 30} = outcome2

      resumed_log = Log.prepare_for_retrace(outcome2.outputs[EffectLogger.Handler])
      resumed_entries = resumed_log.queue

      # First logged step (put 10) should match original
      [%StepLogEntry{effects_queue: [first_effect | _]} | rest] = resumed_entries
      assert first_effect.sig == State
      assert match?(%State.Put{val: 10}, first_effect.data)

      # Following steps should be freshly logged single-effect entries
      assert Enum.all?(rest, fn entry -> length(entry.effects_queue) == 1 end)
    end

    test "state preserved through error resume" do
      make_computation = fn should_error ->
        con [State] do
          _ <- put(100)
          x <- get()
          _ <- put(x + 50)

          if should_error do
            Throw.throw_error(:fail)
          else
            con do
              y <- get()
              return(y)
            end
          end
        end
      end

      # First run - errors
      outcome1 =
        make_computation.(true)
        |> EffectLogger.Handler.run(Log.new())
        |> Throw.Handler.run()
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: {:error, :fail}} = outcome1
      # State should be 150 at error point
      assert outcome1.outputs[State.Handler] == 150

      # Resume with fix
      log = outcome1.outputs[EffectLogger.Handler]
      json_log = Jason.encode!(log)
      resume_log = json_log |> Jason.decode!() |> Log.from_json() |> Log.for_error_resume()

      outcome2 =
        make_computation.(false)
        |> EffectLogger.Handler.run(resume_log)
        |> Throw.Handler.run()
        |> State.Handler.run(150)
        |> Run.run()

      # Should complete with state preserved
      assert %RunOutcome{result: {:ok, 150}} = outcome2
      assert outcome2.outputs[State.Handler] == 150
    end
  end
end
