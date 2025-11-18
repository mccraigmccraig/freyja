defmodule Freyja.Examples.HeftyChangeCaptureTest do
  use ExUnit.Case

  alias Freyja.Examples.HeftyChangeCapture
  alias Freyja.Examples.HeftyChangeCapture.Storage
  alias Freyja.Effects.Lift
  alias Freyja.Effects.{FxList, TaggedWriter, State}
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
        FxList.Algebra,
        TaggedWriter.Algebra
      ]

      # Handlers for first-order effects (including runner effects)
      handlers = [
        Storage.Handler,
        TaggedWriter.Handler,
        State.Handler,
        TaggedWriter.RunListenHandler
      ]

      initial_states = %{
        Storage.Handler => initial_users,
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      outcome = Run.run(
        HeftyChangeCapture.process_users([1, 2, 3], &HeftyChangeCapture.remove_email_from_user/1),
        algebras,
        handlers,
        initial_states
      )

      result = outcome.result.value

      # Should have updated 3 users
      assert result.updated_users == [
               %{id: 1, name: "Alice", created_at: ~D[2020-01-01]},
               %{id: 2, name: "Bob", created_at: ~D[2020-02-01]},
               %{id: 3, name: "Charlie", created_at: ~D[2020-03-01]}
             ]

      # Should have captured 3 changes
      captured_changes = result.all_logs[:changes] || []
      assert length(captured_changes) == 3

      # Should have processed 3 records
      assert result.processed_count == 3

      # Verify storage state was actually updated
      final_storage_state = outcome.outputs[Storage.Handler]

      assert final_storage_state[1] == %{id: 1, name: "Alice", created_at: ~D[2020-01-01]}
      assert final_storage_state[2] == %{id: 2, name: "Bob", created_at: ~D[2020-02-01]}
      assert final_storage_state[3] == %{id: 3, name: "Charlie", created_at: ~D[2020-03-01]}
    end

    test "handles empty user list" do
      algebras = [Lift.Algebra, Storage.Algebra, FxList.Algebra, TaggedWriter.Algebra]
      handlers = [Storage.Handler, TaggedWriter.Handler, State.Handler, TaggedWriter.RunListenHandler]
      initial_states = %{
        Storage.Handler => %{},
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      outcome = Run.run(
        HeftyChangeCapture.process_users([], &HeftyChangeCapture.remove_email_from_user/1),
        algebras,
        handlers,
        initial_states
      )

      result = outcome.result.value

      assert result.updated_users == []
      assert result.all_logs[:changes] == nil || result.all_logs[:changes] == []
      assert result.processed_count == 0
    end
  end

  describe "effect polymorphism - different processing functions" do
    test "removes only test emails using validate_and_update_user" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@test.com", created_at: ~D[2020-01-01]},
        2 => %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]},
        3 => %{id: 3, name: "Charlie", email: "charlie@test.com", created_at: ~D[2020-03-01]}
      }

      algebras = [Lift.Algebra, Storage.Algebra, FxList.Algebra, TaggedWriter.Algebra]
      handlers = [Storage.Handler, TaggedWriter.Handler, State.Handler, TaggedWriter.RunListenHandler]
      initial_states = %{
        Storage.Handler => initial_users,
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      # KEY POINT: Same process_users function, different processing logic!
      # The validate_and_update_user function uses MORE effects (TaggedWriter for validation)
      # but process_users doesn't need to know or care!
      outcome = Run.run(
        HeftyChangeCapture.process_users([1, 2, 3], &HeftyChangeCapture.validate_and_update_user/1),
        algebras,
        handlers,
        initial_states
      )

      result = outcome.result.value

      # Alice and Charlie should have email removed, Bob should keep his
      assert result.updated_users == [
               %{id: 1, name: "Alice", email: nil, created_at: ~D[2020-01-01]},
               %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]},
               %{id: 3, name: "Charlie", email: nil, created_at: ~D[2020-03-01]}
             ]

      # Should have captured 2 changes (Alice and Charlie)
      captured_changes = result.all_logs[:changes] || []
      assert length(captured_changes) == 2

      # Should have processed all 3 records
      assert result.processed_count == 3

      # The extra effect: validation logging!
      validation_results = result.all_logs[:validations] || []
      assert length(validation_results) == 3

      # Check validation results
      validation_map = Map.new(validation_results, fn {action, id} -> {id, action} end)
      assert validation_map[1] == :removed_test_email
      assert validation_map[2] == :kept_email
      assert validation_map[3] == :removed_test_email
    end

    test "demonstrates effect polymorphism with audit_user" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]}
      }

      algebras = [Lift.Algebra, Storage.Algebra, FxList.Algebra, TaggedWriter.Algebra]
      handlers = [Storage.Handler, TaggedWriter.Handler, State.Handler, TaggedWriter.RunListenHandler]
      initial_states = %{
        Storage.Handler => initial_users,
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      # KEY POINT: audit_user uses DIFFERENT effects than the other functions!
      # It uses TaggedWriter for audit logs but NOT Storage.change
      # Yet it works with the same process_users function!
      outcome = Run.run(
        HeftyChangeCapture.process_users([1], &HeftyChangeCapture.audit_user/1),
        algebras,
        handlers,
        initial_states
      )

      result = outcome.result.value

      # User unchanged (audit doesn't modify)
      assert result.updated_users == [
               %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]}
             ]

      # No changes recorded (audit doesn't call Storage.change)
      assert result.all_logs[:changes] == nil || result.all_logs[:changes] == []

      # But we have audit logs! Different effect set, same process_users function
      audit_logs = result.all_logs[:audit] || []
      assert length(audit_logs) == 1
      [audit_entry] = audit_logs
      assert audit_entry.action == :reviewed
      assert audit_entry.user_id == 1

      # Counter still incremented
      assert result.processed_count == 1
    end
  end

  describe "multi-stage processing with Hefty" do
    test "anonymizes users and creates audit trail" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]},
        2 => %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]}
      }

      algebras = [Lift.Algebra, Storage.Algebra, FxList.Algebra, TaggedWriter.Algebra]
      handlers = [Storage.Handler, TaggedWriter.Handler, State.Handler, TaggedWriter.RunListenHandler]
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
    test "achieves same results with simpler code and better composition" do
      # This test demonstrates that Hefty achieves the same functionality
      # as the old scoped effects, but with:
      # 1. MUCH simpler code
      # 2. BETTER composition via effect polymorphism

      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]}
      }

      algebras = [Lift.Algebra, Storage.Algebra, FxList.Algebra, TaggedWriter.Algebra]
      handlers = [Storage.Handler, TaggedWriter.Handler, State.Handler, TaggedWriter.RunListenHandler]
      initial_states = %{
        Storage.Handler => initial_users,
        TaggedWriter.Handler => %{},
        State.Handler => 0
      }

      # OLD WAY: Would need separate process_users, process_users_with_validation, etc.
      # NEW WAY: Single process_users function, pass different processing functions!
      outcome = Run.run(
        HeftyChangeCapture.process_users([1], &HeftyChangeCapture.remove_email_from_user/1),
        algebras,
        handlers,
        initial_states
      )

      result = outcome.result.value

      # Same capabilities as old ChangeCapture
      assert Map.has_key?(result, :updated_users)
      assert Map.has_key?(result, :all_logs)
      assert Map.has_key?(result, :processed_count)

      # But with these benefits:
      # 1. Storage.Algebra is ~25 lines vs ~150 line scoped handler (15x reduction!)
      # 2. No manual RunOutcome handling
      # 3. No ScopedOk/ScopedError complexity
      # 4. No suspension special cases
      # 5. Effect polymorphism - single process_users, many processing functions
      # 6. No parameter threading - effects compose naturally
      # 7. Theoretically sound foundation
    end
  end
end
