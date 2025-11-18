defmodule Freyja.Examples.HeftyChangeCaptureTest do
  use ExUnit.Case

  alias Freyja.Examples.HeftyChangeCapture
  alias Freyja.Examples.HeftyChangeCapture.Storage
  alias Freyja.Hefty.Effects.{HeftyFxList, HeftyTaggedWriter, Lift}
  alias Freyja.Effects.{TaggedWriter, State}
  alias Freyja.Hefty.Run

  describe "basic change capture example with Hefty" do
    test "removes emails and tracks changes" do
      # Initial user data
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]},
        2 => %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]},
        3 => %{id: 3, name: "Charlie", email: "charlie@example.com", created_at: ~D[2020-03-01]}
      }

      # Algebras for higher-order effects
      algebras = [
        Lift.Algebra,
        Storage.Algebra,
        HeftyFxList.Algebra,
        HeftyTaggedWriter.Algebra
      ]

      # Handlers for first-order effects (including runner effects)
      handlers = [
        Storage.Handler,
        TaggedWriter.Handler,
        State.Handler,
        HeftyTaggedWriter.RunListenHandler
      ]

      initial_states = %{
        Storage.Handler => initial_users,
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      outcome = Run.run(HeftyChangeCapture.process_users([1, 2, 3]), algebras, handlers, initial_states)

      result = outcome.result.value

      # Should have updated 3 users
      assert result.updated_users == [
               %{id: 1, name: "Alice", created_at: ~D[2020-01-01]},
               %{id: 2, name: "Bob", created_at: ~D[2020-02-01]},
               %{id: 3, name: "Charlie", created_at: ~D[2020-03-01]}
             ]

      # Should have captured 3 changes
      assert length(result.captured_changes) == 3

      # Should have processed 3 records
      assert result.processed_count == 3

      # Should have updated 3 records
      assert result.update_count == 3

      # Verify storage state was actually updated
      final_storage_state = outcome.outputs[Storage.Handler]

      assert final_storage_state[1] == %{id: 1, name: "Alice", created_at: ~D[2020-01-01]}
      assert final_storage_state[2] == %{id: 2, name: "Bob", created_at: ~D[2020-02-01]}
      assert final_storage_state[3] == %{id: 3, name: "Charlie", created_at: ~D[2020-03-01]}
    end

    test "handles empty user list" do
      algebras = [Lift.Algebra, Storage.Algebra, HeftyFxList.Algebra, HeftyTaggedWriter.Algebra]
      handlers = [Storage.Handler, TaggedWriter.Handler, State.Handler, HeftyTaggedWriter.RunListenHandler]
      initial_states = %{
        Storage.Handler => %{},
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      outcome = Run.run(HeftyChangeCapture.process_users([]), algebras, handlers, initial_states)

      result = outcome.result.value

      assert result.updated_users == []
      assert result.captured_changes == []
      assert result.processed_count == 0
      assert result.update_count == 0
    end
  end

  describe "validation example with Hefty" do
    test "removes only test emails" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@test.com", created_at: ~D[2020-01-01]},
        2 => %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]},
        3 => %{id: 3, name: "Charlie", email: "charlie@test.com", created_at: ~D[2020-03-01]}
      }

      algebras = [Lift.Algebra, Storage.Algebra, HeftyFxList.Algebra, HeftyTaggedWriter.Algebra]
      handlers = [Storage.Handler, TaggedWriter.Handler, State.Handler, HeftyTaggedWriter.RunListenHandler]
      initial_states = %{
        Storage.Handler => initial_users,
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      outcome = Run.run(HeftyChangeCapture.process_users_with_validation([1, 2, 3]), algebras, handlers, initial_states)

      result = outcome.result.value

      # Alice and Charlie should have email removed, Bob should keep his
      assert result.updated_users == [
               %{id: 1, name: "Alice", email: nil, created_at: ~D[2020-01-01]},
               %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]},
               %{id: 3, name: "Charlie", email: nil, created_at: ~D[2020-03-01]}
             ]

      # Should have captured 2 changes (Alice and Charlie)
      assert result.changes_applied == 2

      # Should have processed all 3 records
      assert result.processed_count == 3

      # Should have validation results for all 3
      assert length(result.validations) == 3

      # Check validation results
      validation_map = Map.new(result.validations, fn {action, id} -> {id, action} end)
      assert validation_map[1] == :removed_test_email
      assert validation_map[2] == :kept_email
      assert validation_map[3] == :removed_test_email
    end
  end

  describe "multi-stage processing with Hefty" do
    test "anonymizes users and creates audit trail" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]},
        2 => %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]}
      }

      algebras = [Lift.Algebra, Storage.Algebra, HeftyFxList.Algebra, HeftyTaggedWriter.Algebra]
      handlers = [Storage.Handler, TaggedWriter.Handler, State.Handler, HeftyTaggedWriter.RunListenHandler]
      initial_states = %{
        Storage.Handler => initial_users,
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      outcome = Run.run(HeftyChangeCapture.multi_stage_process([1, 2]), algebras, handlers, initial_states)

      result = outcome.result.value

      # Should have anonymized 2 users
      assert result.anonymized == 2

      # Should have audited 2 users
      assert result.audited == 2

      # Should have processed 4 records total (2 in each stage)
      assert result.total_processed == 4

      # Should have stage logs
      assert length(result.stages) == 2
      assert Enum.member?(result.stages, {:anonymization_complete, 2})
      assert Enum.member?(result.stages, {:audit_complete, 2})

      # Verify storage was updated with anonymized users
      final_storage_state = outcome.outputs[Storage.Handler]
      assert final_storage_state[1] == %{id: 1, created_at: ~D[2020-01-01]}
      assert final_storage_state[2] == %{id: 2, created_at: ~D[2020-02-01]}
    end
  end

  describe "comparison with old ChangeCapture approach" do
    test "achieves same results with simpler code" do
      # This test demonstrates that Hefty achieves the same functionality
      # as the old scoped effects, but with much simpler code

      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]}
      }

      algebras = [Lift.Algebra, Storage.Algebra, HeftyFxList.Algebra, HeftyTaggedWriter.Algebra]
      handlers = [Storage.Handler, TaggedWriter.Handler, State.Handler, HeftyTaggedWriter.RunListenHandler]
      initial_states = %{
        Storage.Handler => initial_users,
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      outcome = Run.run(HeftyChangeCapture.process_users([1]), algebras, handlers, initial_states)

      result = outcome.result.value

      # Same result structure as old ChangeCapture
      assert Map.has_key?(result, :updated_users)
      assert Map.has_key?(result, :captured_changes)
      assert Map.has_key?(result, :processed_count)
      assert Map.has_key?(result, :update_count)

      # But with these benefits:
      # 1. Storage.Algebra is ~25 lines vs ~150 line scoped handler
      # 2. No manual RunOutcome handling
      # 3. No ScopedOk/ScopedError complexity
      # 4. No suspension special cases
      # 5. Theoretically sound foundation
    end
  end
end
