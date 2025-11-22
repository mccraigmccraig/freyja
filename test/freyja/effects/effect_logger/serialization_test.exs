defmodule Freyja.Effects.EffectLogger.SerializationTest do
  use ExUnit.Case
  alias Freyja.Effects.EffectLogger.Log
  alias Freyja.Freer.Impure

  describe "Jason.Encoder for Log structures" do
    test "encodes Log with serializable data" do
      log =
        Log.new()
        |> Log.log_effect(%Impure{sig: :test_sig, data: %{foo: "bar"}})
        |> Log.log_interpreted_effect_value(42)

      json = Jason.encode!(log)
      decoded = Jason.decode!(json)

      # Verify structure is preserved
      assert is_map(decoded)
      assert Map.has_key?(decoded, "stack")
      assert Map.has_key?(decoded, "queue")

      # Verify the data field was included
      [step_entry] = decoded["stack"]
      [effect_entry] = step_entry["effects_stack"]
      assert effect_entry["data"] == %{"foo" => "bar"}
      assert effect_entry["sig"] == "test_sig"
    end

    test "encodes Log with non-serializable data (function)" do
      log =
        Log.new()
        |> Log.log_effect(%Impure{sig: :test_sig, data: fn x -> x + 1 end})
        |> Log.log_interpreted_effect_value(99)

      # Should not raise - non-serializable data should be omitted
      json = Jason.encode!(log)
      decoded = Jason.decode!(json)

      # Verify structure is preserved
      assert is_map(decoded)
      [step_entry] = decoded["stack"]
      [effect_entry] = step_entry["effects_stack"]

      # Data field should be nil (function was not serializable)
      assert effect_entry["data"] == nil
      assert effect_entry["sig"] == "test_sig"

      # But the value is preserved
      assert step_entry["value"] == 99
    end

    test "round-trip encoding preserves structure for serializable data" do
      log =
        Log.new()
        |> Log.log_effect(%Impure{sig: :state_get, data: %{key: "user_id"}})
        |> Log.log_interpreted_effect_value(%{id: 123, name: "Alice"})

      json = Jason.encode!(log)
      decoded = Jason.decode!(json)

      # Verify we can reconstruct the important parts
      assert [step] = decoded["stack"]
      assert step["completed?"] == true
      assert step["value"] == %{"id" => 123, "name" => "Alice"}

      [effect] = step["effects_stack"]
      assert effect["sig"] == "state_get"
      assert effect["data"] == %{"key" => "user_id"}
    end

    test "from_json reconstructs proper structs" do
      original_log =
        Log.new()
        |> Log.log_effect(%Impure{sig: :test_sig, data: %{foo: "bar"}})
        |> Log.log_interpreted_effect_value(42)

      json = Jason.encode!(original_log)
      decoded_map = Jason.decode!(json)
      reconstructed_log = Log.from_json(decoded_map)

      # Verify it's a proper Log struct
      assert %Log{} = reconstructed_log
      assert [step] = reconstructed_log.stack
      assert %Freyja.Effects.EffectLogger.StepLogEntry{} = step
      assert step.completed? == true
      assert step.value == 42

      # Verify nested structs
      [effect] = step.effects_stack
      assert %Freyja.Effects.EffectLogger.EffectLogEntry{} = effect
      assert effect.sig == :test_sig
      assert effect.data == %{"foo" => "bar"}
    end

    test "from_json round-trip" do
      log =
        Log.new()
        |> Log.log_effect(%Impure{sig: :simple, data: "test"})
        |> Log.log_interpreted_effect_value(99)

      json = Jason.encode!(log)
      decoded_map = Jason.decode!(json)
      reconstructed = Log.from_json(decoded_map)

      [step] = reconstructed.stack
      [effect] = step.effects_stack
      # Verify effect is properly reconstructed
      assert effect.sig == :simple
      assert effect.data == "test"
    end
  end
end
