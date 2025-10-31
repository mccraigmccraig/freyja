defmodule Freyja.Effects.EffectLoggerSerializationTest do
  use ExUnit.Case
  alias Freyja.Effects.EffectLogger.{Log, ScopedLogs}
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

    test "encodes ScopedLogs" do
      log1 = Log.new()
        |> Log.log_effect(%Impure{sig: :test1, data: "data1"})
        |> Log.log_interpreted_effect_value(:result1)
        |> Log.prepare_for_retrace()

      log2 = Log.new()
        |> Log.log_effect(%Impure{sig: :test2, data: "data2"})
        |> Log.log_interpreted_effect_value(:result2)
        |> Log.prepare_for_retrace()

      scoped_logs = %ScopedLogs{
        scoped_log_queue: [log1],
        scoped_log_stack: [log2]
      }

      json = Jason.encode!(scoped_logs)
      decoded = Jason.decode!(json)

      assert Map.has_key?(decoded, "scoped_log_queue")
      assert Map.has_key?(decoded, "scoped_log_stack")
      assert length(decoded["scoped_log_queue"]) == 1
      assert length(decoded["scoped_log_stack"]) == 1
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
  end
end
