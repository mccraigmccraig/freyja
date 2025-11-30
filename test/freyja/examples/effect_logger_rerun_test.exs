defmodule Freyja.Examples.EffectLoggerRerunTest do
  use ExUnit.Case, async: true

  require Logger

  alias Freyja.Examples.EffectLoggerRerun
  alias Freyja.Run
  # alias Freyja.Effects.EffectLogger.Handler, as: EffectLoggerHandler

  test "rerun from serialized log" do
    buggy_builder = EffectLoggerRerun.build(:original)
    outcome = Run.run(buggy_builder)
    assert {:error, :validation_failed} = outcome.result

    # Logger.error(
    #   "#{__MODULE__}.outcome\n#{inspect(outcome.outputs[EffectLoggerHandler], pretty: true)}"
    # )

    json = Jason.encode!(outcome)
    decoded = Jason.decode!(json)

    fixed_builder = EffectLoggerRerun.build(:patched)
    rerun_outcome = Run.rerun(fixed_builder, decoded)

    # rerun_outcome.run_state will still have a Throw op on the
    # log queue, from the previous failed run - this gets
    # truncated when the log is finalized, because it's recognized
    # then as an effect from a previous run which _did not execute_
    # in this run (because it's still on the queue)
    # Logger.error(
    #   # "#{__MODULE__}.rerun_outcome\n#{inspect(rerun_outcome.outputs[EffectLoggerHandler], pretty: true)}"
    #   "#{__MODULE__}.rerun_outcome\n#{inspect(rerun_outcome, pretty: true)}"
    # )

    assert {:ok, :ok} = rerun_outcome.result
  end
end
