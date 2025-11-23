defmodule Freyja.Examples.EffectLoggerResume do
  @moduledoc """
  Example showing how a suspended computation can be resumed after serializing
  the `EffectLogger`/`RunOutcome` to JSON.
  """

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.{Coroutine, EffectLogger, State}

  @doc """
  Build the coroutine example.

      alias Freyja.Examples.EffectLoggerResume

      builder = Freyja.Examples.EffectLoggerResume.build()
      outcome = Freyja.Run.run(builder)

      # have a look at the result - the 3rd term is the continuation
      outcome.result

      # let's serialise the outcome
      json = Jason.encode!(outcome)

      deserialized_outcome = json |> Jason.decode!() |> Freyja.Run.RunOutcome.from_json

      # see that the deserialized result has no continuation - functions are not
      # easily serializable
      deserialized_outcome.result

      # but - the compuation can still be resumed! we _follow_ the continuation
      # from the log, feeding the logged effect values to each step until we
      # reach the Yield effect, at which point the given value is supplied and
      # normal computation continues
      resumed = Freyja.Run.resume(builder, deserialized_outcome, 42)
  """
  def build do
    sample_computation()
    |> EffectLogger.Handler.run(EffectLogger.Log.new())
    |> Coroutine.Handler.run()
    |> State.Handler.run(0)
  end

  defp sample_computation do
    con [Coroutine, State] do
      _ <- State.put(5)
      value <- Coroutine.yield("resume_me")
      _ <- State.put(value)
      return(value)
    end
  end
end
