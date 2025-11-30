defmodule Freyja.EffectLoggerYieldTest do
  use ExUnit.Case

  require Logger

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.EffectLogger
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
      # nil indicates not completed yet
      assert incomplete_entry.completed? == nil
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
      builder =
        computation
        |> EffectLogger.Handler.run(EffectLogger.Log.new())
        |> Coroutine.Handler.run()
        |> State.Handler.run(0)

      outcome1 = builder |> Run.run()

      assert %RunOutcome{result: {:suspend, "suspend here", _k}} = outcome1
      outcome2 = Run.resume(builder, outcome1, 999)

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
      builder =
        computation
        |> EffectLogger.Handler.run(EffectLogger.Log.new())
        |> Coroutine.Handler.run()
        |> State.Handler.run(0)

      outcome1 = builder |> Run.run()

      assert %RunOutcome{result: {:suspend, 100, _k}} = outcome1

      json_outcome = Jason.encode!(outcome1)
      decoded_outcome = json_outcome |> Jason.decode!()

      outcome2 = Run.resume(builder, decoded_outcome, 50)

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
      builder =
        computation
        |> EffectLogger.Handler.run(EffectLogger.Log.new())
        |> Coroutine.Handler.run()
        |> State.Handler.run(0)

      outcome1 = builder |> Run.run()

      assert %RunOutcome{result: {:suspend, "first", _k}} = outcome1

      outcome2 = Run.resume(builder, outcome1, 20)

      # Should suspend at second yield
      assert %RunOutcome{result: {:suspend, "second", _k2}} = outcome2
      assert outcome2.outputs[State.Handler] == 20

      outcome3 = Run.resume(builder, outcome2, 30)

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
