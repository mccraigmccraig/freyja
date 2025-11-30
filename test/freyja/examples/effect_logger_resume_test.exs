defmodule Freyja.Examples.EffectLoggerResumeTest do
  use ExUnit.Case, async: true

  require Logger

  alias Freyja.Examples.EffectLoggerResume
  alias Freyja.Run
  # alias Freyja.Effects.EffectLogger.Handler, as: EffectLoggerHandler

  test "resume suspended computation from serialized outcome" do
    builder = EffectLoggerResume.build()
    outcome = Run.run(builder)

    assert {:suspend, "resume_me", _} = outcome.result

    # Logger.error(
    #   "#{__MODULE__}.outcome\n#{inspect(outcome.outputs[EffectLoggerHandler], pretty: true)}"
    # )

    json = Jason.encode!(outcome)
    decoded = Jason.decode!(json)

    resumed = Run.resume(builder, decoded, 42)

    # Logger.error(
    #   "#{__MODULE__}.resumed\n#{inspect(resumed.outputs[EffectLoggerHandler], pretty: true)}"
    # )

    assert {:done, 42} = resumed.result
  end
end
