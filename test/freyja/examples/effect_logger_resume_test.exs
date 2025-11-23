defmodule Freyja.Examples.EffectLoggerResumeTest do
  use ExUnit.Case, async: true

  alias Freyja.Examples.EffectLoggerResume
  alias Freyja.Run

  test "resume suspended computation from serialized outcome" do
    builder = EffectLoggerResume.build()
    outcome = Run.run(builder)

    assert {:suspend, "resume_me", _} = outcome.result

    json = Jason.encode!(outcome)
    decoded = Jason.decode!(json)

    resumed = Run.resume(builder, decoded, 42)
    assert {:done, 42} = resumed.result
  end
end
