if Code.ensure_loaded?(Ecto) do
  defmodule Freyja.Examples.EctoChangeCaptureTest do
    @moduledoc """
    Tests for the EctoChangeCapture example module.

    These tests demonstrate how to use EctoFx.capture/1 for:
    - Capturing changes without persisting
    - Dry-run mode for batch operations
    - Combining change capture with transactions
    """

    use ExUnit.Case, async: true

    alias Freyja.Examples.EctoChangeCapture
    alias Freyja.Examples.EctoChangeCapture.AuditLog
    alias Freyja.Examples.EctoChangeCapture.User
    alias Freyja.Run

    # ============================================================================
    # Test Fixtures
    # ============================================================================

    defp make_user(id, attrs) do
      %User{
        id: id,
        name: attrs[:name] || "User #{id}",
        email: attrs[:email] || "user#{id}@example.com",
        status: attrs[:status] || "active",
        anonymized_at: nil,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    end

    defp test_users do
      %{
        "user-1" => make_user("user-1", %{name: "Alice", email: "alice@example.com"}),
        "user-2" => make_user("user-2", %{name: "Bob", email: "bob@example.com"}),
        "user-3" =>
          make_user("user-3", %{name: "Carol", email: "carol@example.com", status: "inactive"})
      }
    end

    # ============================================================================
    # anonymize_users_with_capture/1
    # ============================================================================

    describe "anonymize_users_with_capture/1" do
      test "captures update changesets for each user" do
        users = test_users()

        outcome =
          EctoChangeCapture.anonymize_users_with_capture(["user-1", "user-2"])
          |> EctoChangeCapture.test_builder(users)
          |> Run.run()

        assert {:ok, {anonymized_users, captured_changes}} = outcome.result

        # Should have anonymized 2 users
        assert length(anonymized_users) == 2

        # All returned users should be anonymized
        Enum.each(anonymized_users, fn user ->
          assert user.name == "Anonymous"
          assert user.email == nil
          assert user.status == "anonymized"
          assert user.anonymized_at != nil
        end)

        # Should have captured 2 updates (user anonymizations)
        assert length(captured_changes.updates) == 2

        # Should have captured 2 inserts (audit logs)
        assert length(captured_changes.inserts) == 2

        # Verify the captured update changesets
        Enum.each(captured_changes.updates, fn changeset ->
          assert changeset.data.__struct__ == User
          changes = changeset.changes
          assert changes.name == "Anonymous"
          assert changes.email == nil
          assert changes.status == "anonymized"
        end)

        # Verify the captured insert changesets are audit logs
        Enum.each(captured_changes.inserts, fn changeset ->
          assert changeset.data.__struct__ == AuditLog
          changes = changeset.changes
          assert changes.action == "anonymize"
        end)
      end

      test "handles empty user list" do
        outcome =
          EctoChangeCapture.anonymize_users_with_capture([])
          |> EctoChangeCapture.test_builder(%{})
          |> Run.run()

        assert {:ok, {anonymized_users, captured_changes}} = outcome.result

        assert anonymized_users == []
        assert captured_changes.updates == []
        assert captured_changes.inserts == []
        assert captured_changes.deletes == []
      end
    end

    # ============================================================================
    # process_users_conditionally/1
    # ============================================================================

    describe "process_users_conditionally/1" do
      test "deactivates active users and deletes inactive users" do
        users = test_users()

        outcome =
          EctoChangeCapture.process_users_conditionally(["user-1", "user-2", "user-3"])
          |> EctoChangeCapture.test_builder(users)
          |> Run.run()

        assert {:ok, result} = outcome.result
        results = result.results
        changes = result.changes

        # user-1 and user-2 are active -> should be deactivated
        # user-3 is inactive -> should be deleted
        assert length(results) == 3

        # Check results for each user
        [r1, r2, r3] = results

        assert {:deactivated, user1} = r1
        assert user1.status == "inactive"

        assert {:deactivated, user2} = r2
        assert user2.status == "inactive"

        assert {:deleted, user3} = r3
        assert user3.id == "user-3"

        # Should have 2 updates (deactivations) and 1 delete
        assert length(changes.updates) == 2
        assert length(changes.deletes) == 1
        assert changes.inserts == []
      end

      test "skips users with unknown status" do
        users = %{
          "user-1" => make_user("user-1", %{status: "pending"})
        }

        outcome =
          EctoChangeCapture.process_users_conditionally(["user-1"])
          |> EctoChangeCapture.test_builder(users)
          |> Run.run()

        assert {:ok, result} = outcome.result
        [{:skipped, user}] = result.results

        assert user.id == "user-1"
        assert result.changes.updates == []
        assert result.changes.deletes == []
        assert result.changes.inserts == []
      end
    end

    # ============================================================================
    # create_users_batch/1
    # ============================================================================

    describe "create_users_batch/1" do
      test "captures insert changesets for valid users" do
        attrs_list = [
          %{name: "New User 1", email: "new1@example.com"},
          %{name: "New User 2", email: "new2@example.com"}
        ]

        outcome =
          EctoChangeCapture.create_users_batch(attrs_list)
          |> EctoChangeCapture.test_builder(%{})
          |> Run.run()

        assert {:ok, result} = outcome.result

        # Both users should be created successfully
        assert length(result.users) == 2
        assert result.errors == []

        # Should have 2 insert changesets
        assert length(result.changes.inserts) == 2
        assert result.changes.updates == []
        assert result.changes.deletes == []

        # Verify the created users
        [user1, user2] = result.users
        assert user1.name == "New User 1"
        assert user2.name == "New User 2"
      end

      test "separates valid and invalid users" do
        attrs_list = [
          %{name: "Valid User", email: "valid@example.com"},
          # missing email - will fail validation
          %{name: "Invalid User"},
          %{name: "Another Valid", email: "another@example.com"}
        ]

        outcome =
          EctoChangeCapture.create_users_batch(attrs_list)
          |> EctoChangeCapture.test_builder(%{})
          |> Run.run()

        assert {:ok, result} = outcome.result

        # 2 valid, 1 invalid
        assert length(result.users) == 2
        assert length(result.errors) == 1

        # Only 2 insert changesets (for valid users)
        assert length(result.changes.inserts) == 2

        # Check the error changeset
        [error_changeset] = result.errors
        refute error_changeset.valid?
        assert {:email, {"can't be blank", _}} = hd(error_changeset.errors)
      end
    end

    # ============================================================================
    # demonstrate_change_helpers/1
    # ============================================================================

    describe "demonstrate_change_helpers/1" do
      test "provides change statistics and grouping" do
        users = test_users()

        outcome =
          EctoChangeCapture.demonstrate_change_helpers(["user-1", "user-2"])
          |> EctoChangeCapture.test_builder(users)
          |> Run.run()

        assert {:ok, result} = outcome.result

        # Check the statistics
        assert result.update_count == 2
        assert result.insert_count == 0
        assert result.delete_count == 0

        # Check that grouped_by_schema works
        grouped = result.grouped_by_schema
        assert Map.has_key?(grouped, User)
        assert length(grouped[User]) == 2

        # Verify raw_changes structure
        assert is_list(result.raw_changes.updates)
        assert is_list(result.raw_changes.inserts)
        assert is_list(result.raw_changes.deletes)
      end
    end

    # ============================================================================
    # Change capture semantics
    # ============================================================================

    describe "change capture semantics" do
      test "captured changes are not persisted" do
        users = test_users()

        outcome =
          EctoChangeCapture.anonymize_users_with_capture(["user-1"])
          |> EctoChangeCapture.test_builder(users)
          |> Run.run()

        # Get the handler state to verify no actual operations were performed
        # (The test handler tracks all operations)
        # Since we're using TestHandler, the "changes" are just captured, not executed
        assert {:ok, {_anonymized, captured}} = outcome.result

        # Captured changes should be changesets, not persisted records
        Enum.each(captured.updates, fn changeset ->
          assert %Ecto.Changeset{} = changeset
          # The changeset should have the User struct as its data
          assert %User{} = changeset.data
        end)
      end

      test "changes from nested computations are aggregated" do
        # Create users that will exercise both branches
        users = %{
          "user-1" => make_user("user-1", %{status: "active"}),
          "user-2" => make_user("user-2", %{status: "inactive"})
        }

        outcome =
          EctoChangeCapture.process_users_conditionally(["user-1", "user-2"])
          |> EctoChangeCapture.test_builder(users)
          |> Run.run()

        assert {:ok, result} = outcome.result
        changes = result.changes

        # Both update and delete should be captured from different branches
        # from active user deactivation
        assert length(changes.updates) == 1
        # from inactive user deletion
        assert length(changes.deletes) == 1
      end
    end
  end
end
