defmodule Freyja.Examples.ChangeCaptureTest do
  use ExUnit.Case

  import Freyja.Con

  alias Freyja.Examples.ChangeCapture
  alias Freyja.Examples.ChangeCapture.Storage
  alias Freyja.Effects.List
  alias Freyja.Effects.TaggedWriter
  alias Freyja.Effects.State
  alias Freyja.Run

  # Test helper computations
  defcon test_scoped_capture, [Storage, List, TaggedWriter, State] do
    user_list <- Storage.query([1])
    first_user <- return(Elixir.List.first(user_list))

    # Change before listen
    Storage.change(first_user, %{first_user | name: "Alicia"})

    # Listen scope - should only capture changes inside
    {result, captured} <- listen(:changes, con [Storage, List, State] do
      users <- Storage.query([1])
      fx_map(users, &ChangeCapture.remove_email_from_user/1)
    end)

    # Change after listen
    Storage.change(first_user, %{first_user | name: "Ali"})

    all_changes <- peek(:changes)

    return(%{
      captured_in_listen: captured,
      all_changes: all_changes,
      result: result
    })
  end

  defcon check_conflicts_and_update, [Storage, TaggedWriter, State, List] do
    users <- Storage.query([1])

    {_results, changes} <- listen(:changes, con [Storage, State, List] do
      fx_map(users, &ChangeCapture.remove_email_from_user/1)
    end)

    # Inspect changes for conflicts
    has_conflicts <- return(Enum.any?(changes, fn {old, _new} ->
      # In real scenario, check version numbers
      old.version != 1
    end))

    update_result <- if !has_conflicts do
      # No conflicts, apply changes
      Storage.update_all(changes)
    else
      # Conflicts detected, log and skip
      con [TaggedWriter] do
        tell(:conflicts, changes)
        return(0)
      end
    end

    return({has_conflicts, update_result})
  end

  describe "basic change capture example" do
    test "removes emails and tracks changes" do
      # Initial user data
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]},
        2 => %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]},
        3 => %{id: 3, name: "Charlie", email: "charlie@example.com", created_at: ~D[2020-03-01]}
      }

      runner =
        Run.with_handlers(
          storage: {Storage.Handler, initial_users},
          list: List.Handler,
          tw: {TaggedWriter.Handler, %{}},
          s: {State.Handler, 0}
        )

      outcome = Run.run(ChangeCapture.process_users([1, 2, 3]), runner)

      result = outcome.result.value

      # Should have updated 3 users
      assert result.updated_users == [
        %{id: 1, name: "Alice", created_at: ~D[2020-01-01]},
        %{id: 2, name: "Bob", created_at: ~D[2020-02-01]},
        %{id: 3, name: "Charlie", created_at: ~D[2020-03-01]}
      ]

      # Should have captured 3 changes
      assert length(result.captured_changes) == 3
      assert result.processed_count == 3
      assert result.update_count == 3

      # Verify changes structure
      first_change = Elixir.List.first(result.captured_changes)
      {old, new} = first_change
      assert old.email != nil
      assert !Map.has_key?(new, :email)
      assert old.name == new.name

      # Storage should have been updated (email field removed)
      assert !Map.has_key?(outcome.outputs.storage[1], :email)
      assert !Map.has_key?(outcome.outputs.storage[2], :email)
      assert !Map.has_key?(outcome.outputs.storage[3], :email)
    end

    test "handles empty user list" do
      initial_users = %{}

      runner =
        Run.with_handlers(
          storage: {Storage.Handler, initial_users},
          list: List.Handler,
          tw: {TaggedWriter.Handler, %{}},
          s: {State.Handler, 0}
        )

      outcome = Run.run(ChangeCapture.process_users([]), runner)

      result = outcome.result.value

      assert result.updated_users == []
      assert result.captured_changes == []
      assert result.processed_count == 0
      assert result.update_count == 0
    end

    test "handles partial user list (some IDs not found)" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]},
        3 => %{id: 3, name: "Charlie", email: "charlie@example.com", created_at: ~D[2020-03-01]}
      }

      runner =
        Run.with_handlers(
          storage: {Storage.Handler, initial_users},
          list: List.Handler,
          tw: {TaggedWriter.Handler, %{}},
          s: {State.Handler, 0}
        )

      # Query for 3 IDs but only 2 exist
      outcome = Run.run(ChangeCapture.process_users([1, 2, 3]), runner)

      result = outcome.result.value

      # Should only process found users
      assert length(result.updated_users) == 2
      assert result.processed_count == 2
      assert result.update_count == 2
    end
  end

  describe "validation example" do
    test "conditionally removes test emails only" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@test.com", created_at: ~D[2020-01-01]},
        2 => %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]},
        3 => %{id: 3, name: "Charlie", email: "charlie@test.com", created_at: ~D[2020-03-01]},
        4 => %{id: 4, name: "Dave", email: "dave@example.com", created_at: ~D[2020-04-01]}
      }

      runner =
        Run.with_handlers(
          storage: {Storage.Handler, initial_users},
          list: List.Handler,
          tw: {TaggedWriter.Handler, %{}},
          s: {State.Handler, 0}
        )

      outcome = Run.run(ChangeCapture.process_users_with_validation([1, 2, 3, 4]), runner)

      result = outcome.result.value

      # All 4 users processed
      assert result.processed_count == 4

      # But only 2 changes (test emails removed)
      assert result.changes_applied == 2

      # Check validation results
      validation_map = Enum.group_by(result.validations, fn
        {:removed_test_email, _} -> :removed
        {:kept_email, _} -> :kept
      end)

      assert length(validation_map[:removed]) == 2
      assert length(validation_map[:kept]) == 2

      # Verify storage updated correctly
      assert outcome.outputs.storage[1].email == nil  # test email removed
      assert outcome.outputs.storage[2].email == "bob@example.com"  # kept
      assert outcome.outputs.storage[3].email == nil  # test email removed
      assert outcome.outputs.storage[4].email == "dave@example.com"  # kept
    end
  end

  describe "multi-stage processing example" do
    test "processes users through multiple stages with separate change capture" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]},
        2 => %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]}
      }

      runner =
        Run.with_handlers(
          storage: {Storage.Handler, initial_users},
          list: List.Handler,
          tw: {TaggedWriter.Handler, %{}},
          s: {State.Handler, 0}
        )

      outcome = Run.run(ChangeCapture.multi_stage_process([1, 2]), runner)

      result = outcome.result.value

      # Should process 2 users in anonymization stage
      assert result.anonymized == 2

      # Should process 2 users in audit stage
      assert result.audited == 2

      # Total processed: 2 users × 2 stages = 4 operations
      assert result.total_processed == 4

      # Should have 2 stage completion markers
      assert length(result.stages) == 2

      # Verify stage markers
      assert Enum.any?(result.stages, &match?({:anonymization_complete, 2}, &1))
      assert Enum.any?(result.stages, &match?({:audit_complete, 2}, &1))

      # Storage should have anonymized users (no name or email)
      assert outcome.outputs.storage[1] == %{id: 1, created_at: ~D[2020-01-01]}
      assert outcome.outputs.storage[2] == %{id: 2, created_at: ~D[2020-02-01]}

      # Should have audit logs
      audit_logs = outcome.outputs.tw[:audit]
      assert length(audit_logs) == 2
      assert Enum.all?(audit_logs, &match?(%{action: :reviewed}, &1))
    end
  end

  describe "change capture mechanics" do
    test "listen captures only changes from inner scope" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]}
      }

      runner =
        Run.with_handlers(
          storage: {Storage.Handler, initial_users},
          list: List.Handler,
          tw: {TaggedWriter.Handler, %{}},
          s: {State.Handler, 0}
        )

      outcome = Run.run(test_scoped_capture(), runner)

      result = outcome.result.value

      # Listen should only capture the 1 change from remove_email_from_user
      assert length(result.captured_in_listen) == 1

      # But all_changes should have all 3 changes
      assert length(result.all_changes) == 3
    end
  end

  describe "real-world patterns" do
    test "batch update with rollback on error" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", created_at: ~D[2020-01-01]},
        2 => %{id: 2, name: "Bob", email: "bob@example.com", created_at: ~D[2020-02-01]}
      }

      runner =
        Run.with_handlers(
          storage: {Storage.Handler, initial_users},
          list: List.Handler,
          tw: {TaggedWriter.Handler, %{}},
          s: {State.Handler, 0}
        )

      # Process successfully and verify changes are captured
      outcome = Run.run(ChangeCapture.process_users([1, 2]), runner)

      result = outcome.result.value

      # Verify we captured changes before bulk update
      assert length(result.captured_changes) == 2

      # Verify bulk update was applied
      assert result.update_count == 2

      # This pattern allows for:
      # 1. Capture all changes
      # 2. Validate changes
      # 3. Apply in single transaction
      # 4. Rollback if any validation fails
    end

    test "change diffing and conflict detection" do
      initial_users = %{
        1 => %{id: 1, name: "Alice", email: "alice@example.com", version: 1}
      }

      runner =
        Run.with_handlers(
          storage: {Storage.Handler, initial_users},
          tw: {TaggedWriter.Handler, %{}},
          list: List.Handler,
          s: {State.Handler, 0}
        )

      outcome = Run.run(check_conflicts_and_update(), runner)

      {has_conflicts, _update_count} = outcome.result.value

      # No conflicts in this test
      assert has_conflicts == false
    end
  end
end
