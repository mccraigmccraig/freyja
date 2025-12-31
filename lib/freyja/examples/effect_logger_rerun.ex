defmodule Freyja.Examples.EffectLoggerRerun do
  @moduledoc """
  Example showing how `EffectLogger` logs can be serialized and fed back into
  `Run.rerun/2` to debug or continue after fixing code.
  """

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.State
  alias Freyja.Effects.Throw

  @doc """
  Build a builder for the buggy (:original) or fixed (:patched) version.
      alias Freyja.Examples.EffectLoggerRerun

      builder = EffectLoggerRerun.build(:original)
      outcome = Freyja.Run.run(builder)

      # see that it failed!
      outcome.result

      # now let's serialize the outcome
      json = Jason.encode!(outcome)

      # fix the bug in our code
      fixed_builder = EffectLoggerRerun.build(:patched)

      # and rerun from our log... all effects will
      # be fulfilled from their logged version, apart from the
      # final effect, where the logged result will be ignored
      # (this is a feature of the `rerun` function) and
      # actually handled
      rerun = Freyja.Run.rerun(fixed_builder, Jason.decode!(json))
  """
  def build(version \\ :original) do
    computation = sample_computation(version)

    computation
    |> EffectLogger.Handler.run(EffectLogger.Log.new())
    |> Throw.Handler.run()
    |> State.Handler.run(0)
  end

  defp sample_computation(version) do
    con [State, Throw] do
      _ <- State.put(10)
      x <- State.get()

      case version do
        :original ->
          if x == 10 do
            Throw.throw_error(:validation_failed)
          else
            return(:ok)
          end

        :patched ->
          if x == 10 do
            return(:ok)
          else
            Throw.throw_error(:unexpected_state)
          end
      end
    end
  end
end
