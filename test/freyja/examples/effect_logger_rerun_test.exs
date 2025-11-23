defmodule Freyja.Examples.EffectLoggerRerunTest do
  use ExUnit.Case, async: true

  alias Freyja.Examples.EffectLoggerRerun
  alias Freyja.Run

  test "rerun from serialized log" do
    buggy_builder = EffectLoggerRerun.build(:original)
    outcome = Run.run(buggy_builder)
    assert {:error, :validation_failed} = outcome.result

    json = Jason.encode!(outcome)
    decoded = Jason.decode!(json)

    fixed_builder = EffectLoggerRerun.build(:patched)
    rerun_outcome = Run.rerun(fixed_builder, decoded)

    assert {:ok, :ok} = rerun_outcome.result
  end
end
