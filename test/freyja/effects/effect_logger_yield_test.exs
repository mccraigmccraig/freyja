defmodule Freyja.EffectLoggerYieldTest do
  use ExUnit.Case

  require Logger

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.EffectLogger.Log
  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.State
  alias Freyja.Run
  alias Freyja.Run.RunOutcome

  describe "EffectLogger with Coroutine.yield" do
    test "log contains incomplete entry when computation suspends" do
      computation =
        con [Coroutine, State] do
          _ <- put(10)
          x <- get()
          _ <- put(x + 5)
          _ <- yield("suspend here")
          y <- get()
          _ <- put(y * 2)
          return(y)
        end

      outcome =
        computation
        |> EffectLogger.Handler.run(EffectLogger.Log.new())
        |> Coroutine.Handler.run()
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: {:suspend, "suspend here", _k}} = outcome

      log = outcome.outputs[EffectLogger.Handler]

      # Should have 3 completed State effects on the stack
      assert length(log.stack) == 3

      # Should have 1 incomplete Yield in the queue
      assert [incomplete_entry] = log.queue
      assert incomplete_entry.completed? == false
      assert [%EffectLogger.EffectLogEntry{sig: Coroutine}] = incomplete_entry.effects_queue
    end

    test "resume suspended computation from log with resume_value" do
      computation =
        con [Coroutine, State] do
          _ <- put(10)
          x <- get()
          _ <- put(x + 5)
          resumed_value <- yield("suspend here")
          _ <- put(resumed_value)
          y <- get()
          return(y)
        end

      # First run - suspends
      outcome1 =
        computation
        |> EffectLogger.Handler.run(EffectLogger.Log.new())
        |> Coroutine.Handler.run()
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: {:suspend, "suspend here", _k}} = outcome1
      log_after_suspend = outcome1.outputs[EffectLogger.Handler]
      state_after_suspend = outcome1.outputs[State.Handler]

      # Prepare log for resume (already has incomplete Yield entry)
      resume_log = Log.prepare_for_retrace(log_after_suspend)

      # Second run - resume from log with resume_value
      outcome2 =
        computation
        |> EffectLogger.Handler.run(resume_log)
        |> Coroutine.Handler.run(%{resume_value: 999})
        |> State.Handler.run(state_after_suspend)
        |> Run.run()

      # Should complete successfully
      # Note: result format depends on handlers - without Coroutine wrapping it's just the value
      assert %RunOutcome{result: result} = outcome2
      # If Coroutine.Handler finalizes, it wraps in {:done, _}
      actual_value =
        case result do
          {:done, v} -> v
          v -> v
        end

      assert actual_value == 999
      assert outcome2.outputs[State.Handler] == 999
    end

    test "resume from serialized log" do
      computation =
        con [Coroutine, State] do
          _ <- put(100)
          x <- get()
          resumed_value <- yield(x)
          _ <- put(x + resumed_value)
          y <- get()
          return(y)
        end

      # First run - suspends
      outcome1 =
        computation
        |> EffectLogger.Handler.run(EffectLogger.Log.new())
        |> Coroutine.Handler.run()
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: {:suspend, 100, _k}} = outcome1

      # Serialize the log
      log = outcome1.outputs[EffectLogger.Handler]
      state = outcome1.outputs[State.Handler]
      json_log = Jason.encode!(log)

      # Deserialize and resume
      resume_log = json_log |> Jason.decode!() |> Log.from_json()

      outcome2 =
        computation
        |> EffectLogger.Handler.run(resume_log)
        |> Coroutine.Handler.run(%{resume_value: 50})
        |> State.Handler.run(state)
        |> Run.run()

      # Should complete: 100 + 50 = 150
      assert %RunOutcome{result: {:done, 150}} = outcome2
      assert outcome2.outputs[State.Handler] == 150
    end

    test "multiple yields - resume from first yield" do
      computation =
        con [Coroutine, State] do
          _ <- put(10)
          v1 <- yield("first")
          _ <- put(v1)
          v2 <- yield("second")
          _ <- put(v2)
          y <- get()
          return(y)
        end

      # First run - suspends at first yield
      outcome1 =
        computation
        |> EffectLogger.Handler.run(EffectLogger.Log.new())
        |> Coroutine.Handler.run()
        |> State.Handler.run(0)
        |> Run.run()

      assert %RunOutcome{result: {:suspend, "first", _k}} = outcome1

      log1 = outcome1.outputs[EffectLogger.Handler]
      # Logger.error("#{__MODULE__}.log1 pre: \n#{inspect(log1, pretty: true)}")
      # Resume from log - should suspend at second yield
      log1 = Log.prepare_for_retrace(log1)
      # Logger.error("#{__MODULE__}.log1 post: \n#{inspect(log1, pretty: true)}")
      state1 = outcome1.outputs[State.Handler]

      outcome2 =
        computation
        |> EffectLogger.Handler.run(log1)
        |> Coroutine.Handler.run(%{resume_value: 20})
        |> State.Handler.run(state1)
        |> Run.run()

      # Should suspend at second yield
      assert %RunOutcome{result: {:suspend, "second", _k2}} = outcome2
      assert outcome2.outputs[State.Handler] == 20

      log2 = outcome2.outputs[EffectLogger.Handler]
      # Logger.error("#{__MODULE__}.log2 pre: \n#{inspect(log2, pretty: true)}")

      # Resume from second yield
      log2 = Log.prepare_for_retrace(log2)
      # Logger.error("#{__MODULE__}.log2 post: \n#{inspect(log2, pretty: true)}")
      state2 = outcome2.outputs[State.Handler]

      outcome3 =
        computation
        |> EffectLogger.Handler.run(log2)
        |> Coroutine.Handler.run(%{resume_value: 30})
        |> State.Handler.run(state2)
        |> Run.run()

      # Should complete
      assert %RunOutcome{result: result3} = outcome3

      actual_value3 =
        case result3 do
          {:done, v} -> v
          v -> v
        end

      assert actual_value3 == 30
      assert outcome3.outputs[State.Handler] == 30
    end
  end
end
