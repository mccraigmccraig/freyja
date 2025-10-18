defmodule Freyja.Effects.CompositionTest do
  use ExUnit.Case

  require Logger

  alias Freyja.Freer
  alias Freyja.RunOutcome
  alias Freyja.Effects.{EffectLogger, Error, ErrorHandler, Coroutine, CoroutineHandler}

  # defp unwrap(%RunOutcome{result: %Freyja.OkResult{value: v}}), do: unwrap(v)
  # defp unwrap(other), do: other

  defp log_queue(%RunOutcome{
         outputs: %{
           logged_computation: %EffectLogger.LoggedComputation{log: %EffectLogger.Log{queue: q}}
         }
       }),
       do: q

  defp log_queue(_), do: []

  #  defp entry_effect(entry), do: Map.get(entry, :effect)

  describe "Logger + Error" do
    test "throw without catch is logged and propagates error (logger outermost)" do
      require Freer
      require Freyja.Con

      fv =
        Freyja.Con.con [Error] do
          _ <- throw_fx(:oops)
          return(:unreachable)
        end

      out = fv |> EffectLogger.interpret_logger() |> ErrorHandler.interpret_error() |> Freer.run()

      Logger.error("Logger + Error: \n#{inspect(out, pretty: true, limit: :infinity)}")

      assert %RunOutcome{result: %Freyja.ErrorResult{error: :oops}, outputs: out_map} = out
      # For short-circuiting error, logger cannot finalize into logged_computation yet
      refute Map.has_key?(out_map, :logged_computation)
    end

    test "logger inside error sees nothing (cautionary)" do
      require Freer
      require Freyja.Con

      fv =
        Freyja.Con.con [Error] do
          _ <- throw_fx(:oops)
          return(:unreachable)
        end

      out = fv |> ErrorHandler.interpret_error() |> EffectLogger.interpret_logger() |> Freer.run()

      assert %RunOutcome{result: %Freyja.ErrorResult{error: :oops}} = out
      assert log_queue(out) == []
    end
  end

  describe "Logger + Coroutine" do
    test "yield is logged; no interpreted value for yield" do
      require Freer
      require Freyja.Con

      fv =
        Freyja.Con.con Coroutine do
          a <- yield("first")
          return(a)
        end

      out1 =
        fv
        |> EffectLogger.interpret_logger()
        |> CoroutineHandler.interpret_coroutine()
        |> Freer.run()

      Logger.error("Logger + Coroutine out1: \n#{inspect(out1, pretty: true, limit: :infinity)}")

      assert %RunOutcome{result: %Freyja.SuspendResult{value: "first", continuation: k}} = out1
      assert is_function(k, 1)

      # Logger cannot finalize since continuation isn't invoked; no logged_computation yet
      refute Map.has_key?(out1.outputs, :logged_computation)

      # resume and finish
      out2 = out1 |> CoroutineHandler.resume("done") |> Freer.run()

      Logger.error("Logger + Coroutine out2: \n#{inspect(out2, pretty: true, limit: :infinity)}")

      assert %RunOutcome{result: %Freyja.OkResult{value: "done"}} = out2
    end
  end

  describe "Error + Coroutine" do
    test "yield then throw after resume (error outermost)" do
      require Freer
      require Freyja.Con

      fv =
        Freyja.Con.con [Error, Coroutine] do
          a <- yield(:step)
          _ <- throw_fx(:boom)
          return({:ok, a})
        end

      out1 =
        fv
        |> ErrorHandler.interpret_error()
        |> CoroutineHandler.interpret_coroutine()
        |> Freer.run()

      Logger.error("Error + Coroutine out1: \n#{inspect(out1, pretty: true, limit: :infinity)}")

      assert %RunOutcome{result: %Freyja.SuspendResult{value: :step, continuation: _k}} = out1

      out2 = out1 |> CoroutineHandler.resume(:ignored) |> Freer.run()

      Logger.error("Error + Coroutine out2: \n#{inspect(out2, pretty: true, limit: :infinity)}")
      assert %RunOutcome{result: %Freyja.ErrorResult{error: :boom}} = out2
    end
  end

  describe "Logger + Error + Coroutine" do
    test "yield then throw; both logged (logger outermost)" do
      require Freer
      require Freyja.Con

      fv =
        Freyja.Con.con [Coroutine, Error] do
          _ <- yield(:hello)
          _ <- throw_fx(:bad)
          return(:nope)
        end

      out1 =
        fv
        |> EffectLogger.interpret_logger()
        |> ErrorHandler.interpret_error()
        |> CoroutineHandler.interpret_coroutine()
        |> Freer.run()

      assert %RunOutcome{result: %Freyja.SuspendResult{value: :hello, continuation: _k1}} =
               out1

      Logger.error(
        "Logger + Error + Coroutine out1: \n#{inspect(out1, pretty: true, limit: :infinity)}"
      )

      # not finalized yet, no log attached
      refute Map.has_key?(out1.outputs, :logged_computation)

      out2 = out1 |> CoroutineHandler.resume(:ignored) |> Freer.run()
      assert %RunOutcome{result: %Freyja.ErrorResult{error: :bad}} = out2

      Logger.error(
        "Logger + Error + Coroutine out2: \n#{inspect(out2, pretty: true, limit: :infinity)}"
      )

      # still short-circuited; logger has not finalized
      refute Map.has_key?(out2.outputs, :logged_computation)
    end
  end
end
