defmodule Freyja.Run.RunOutcomeTest do
  use ExUnit.Case, async: true

  alias Freyja.Run.RunOutcome
  alias Freyja.Run.RunState
  alias Freyja.Run.SerializableResult

  test "Jason encoding omits run_state and wraps result" do
    run_state = %RunState{handlers: [], states: %{}}
    log = Freyja.Effects.EffectLogger.Log.new()
    outcome = RunOutcome.new({:ok, 1}, %{Freyja.Effects.EffectLogger.Log => log}, run_state)

    json = Jason.encode!(outcome)
    decoded = Jason.decode!(json)

    refute Map.has_key?(decoded, "run_state")

    result_meta =
      decoded["result"]
      |> SerializableResult.from_json()

    assert SerializableResult.unwrap(result_meta) == {:ok, 1}

    outputs = decoded["outputs"]
    log_json = outputs["Elixir.Freyja.Effects.EffectLogger.Log"]
    assert log_json["stack"] == []
    assert log_json["queue"] == []
  end

  test "from_json reconstructs outcome without run_state" do
    run_state = %RunState{handlers: [], states: %{}}
    log = Freyja.Effects.EffectLogger.Log.new()
    outcome = RunOutcome.new({:error, :fail}, %{Freyja.Effects.EffectLogger.Log => log}, run_state)

    json = Jason.encode!(outcome)
    decoded = Jason.decode!(json)
    reconstructed = RunOutcome.from_json(decoded)

    assert reconstructed.run_state == nil
    assert reconstructed.result == {:error, :fail}
    assert reconstructed.outputs[Freyja.Effects.EffectLogger.Log]
           == %Freyja.Effects.EffectLogger.Log{queue: [], stack: [], replay_allow_final_divergence?: false}
  end
end
