defmodule Freyja.Effects.EctoFxTest do
  use ExUnit.Case, async: true

  import Freyja.Freer.FreerBlock
  import Freyja.Hefty.HeftyBlock

  alias Freyja.Effects.EctoFx
  alias Freyja.Effects.{FxList, Lift, Throw}
  alias Freyja.Run

  # Test schemas
  defmodule User do
    use Ecto.Schema

    embedded_schema do
      field(:name, :string)
      field(:email, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name, :email])
      |> Ecto.Changeset.validate_required([:name])
    end
  end

  defmodule Order do
    use Ecto.Schema

    embedded_schema do
      field(:total, :integer)
      field(:status, :string)
    end

    def changeset(order \\ %__MODULE__{}, attrs) do
      order
      |> Ecto.Changeset.cast(attrs, [:total, :status])
    end
  end

  # Sample query module
  defmodule SampleQueries do
    def fetch_user(%{id: id}), do: %{id: id, name: "user-#{id}"}
    def list_users(%{limit: limit}), do: Enum.map(1..limit, &%{id: &1, name: "user-#{&1}"})
  end

  # ============================================================================
  # Query Tests
  # ============================================================================

  describe "Ecto.query/3" do
    test "dispatches using :direct registry entry" do
      comp =
        con [EctoFx] do
          EctoFx.query(SampleQueries, :fetch_user, %{id: 1})
        end

      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query(SampleQueries, :fetch_user, %{id: 1}, %{
          id: 1,
          name: "Alice"
        })

      outcome =
        comp
        |> EctoFx.TestHandler.run(state)
        |> Throw.Handler.run()
        |> Run.run()

      assert {:ok, %{id: 1, name: "Alice"}} = outcome.result
    end

    test "returns error when query not stubbed" do
      comp =
        con [EctoFx] do
          EctoFx.query(SampleQueries, :fetch_user, %{id: 99})
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:error, {:query_not_stubbed, _key}} = outcome.result
    end
  end

  describe "Ecto.query_key/3" do
    test "produces canonical keys regardless of map key order" do
      key1 = EctoFx.query_key(SampleQueries, :fetch_user, %{id: 1, extra: %{foo: "bar"}})
      key2 = EctoFx.query_key(SampleQueries, :fetch_user, %{extra: %{foo: "bar"}, id: 1})

      assert key1 == key2
    end
  end

  # ============================================================================
  # Mutation Tests
  # ============================================================================

  describe "Ecto.insert/2" do
    test "insert with valid changeset returns applied changes" do
      changeset = User.changeset(%{name: "Alice", email: "alice@test.com"})

      comp =
        con [EctoFx] do
          EctoFx.insert(changeset)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Run.run()

      assert %User{name: "Alice", email: "alice@test.com"} = outcome.result
    end

    test "insert with invalid changeset returns error via Throw" do
      changeset = User.changeset(%{email: "no-name@test.com"})

      comp =
        con [EctoFx] do
          EctoFx.insert(changeset)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:error, {:changeset_error, %Ecto.Changeset{valid?: false}}} = outcome.result
    end

    test "custom stub overrides default behavior" do
      changeset = User.changeset(%{name: "Bob"})

      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_insert(User, fn _cs ->
          {:ok, %User{id: "custom-id", name: "Stubbed Bob"}}
        end)

      comp =
        con [EctoFx] do
          EctoFx.insert(changeset)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run(state)
        |> Run.run()

      assert %User{id: "custom-id", name: "Stubbed Bob"} = outcome.result
    end
  end

  describe "Ecto.update/2" do
    test "update with valid changeset returns updated struct" do
      user = %User{id: "123", name: "Bob", email: "bob@test.com"}
      changeset = User.changeset(user, %{name: "Robert"})

      comp =
        con [EctoFx] do
          EctoFx.update(changeset)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Run.run()

      assert %User{id: "123", name: "Robert", email: "bob@test.com"} = outcome.result
    end
  end

  describe "Ecto.delete/2" do
    test "delete returns the deleted struct" do
      user = %User{id: "456", name: "Charlie", email: "charlie@test.com"}

      comp =
        con [EctoFx] do
          EctoFx.delete(user)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Run.run()

      assert %User{id: "456", name: "Charlie"} = outcome.result
    end
  end

  describe "Ecto.insert_or_update/2" do
    test "insert_or_update with valid changeset succeeds" do
      changeset = User.changeset(%{name: "Dana", email: "dana@test.com"})

      comp =
        con [EctoFx] do
          EctoFx.insert_or_update(changeset)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Run.run()

      assert %User{name: "Dana", email: "dana@test.com"} = outcome.result
    end
  end

  describe "bulk operations" do
    test "insert_all returns count" do
      entries = [
        %{name: "User1", email: "u1@test.com"},
        %{name: "User2", email: "u2@test.com"},
        %{name: "User3", email: "u3@test.com"}
      ]

      comp =
        con [EctoFx] do
          EctoFx.insert_all(User, entries)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Run.run()

      assert {3, nil} = outcome.result
    end

    test "update_all returns count" do
      comp =
        con [EctoFx] do
          EctoFx.update_all(User, set: [name: "Updated"])
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Run.run()

      assert {0, nil} = outcome.result
    end

    test "delete_all returns count" do
      comp =
        con [EctoFx] do
          EctoFx.delete_all(User)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Run.run()

      assert {0, nil} = outcome.result
    end
  end

  # ============================================================================
  # Change Capture Tests
  # ============================================================================

  describe "Ecto.capture/1" do
    test "captures insert changes" do
      comp =
        hefty do
          {result, changes} <-
            EctoFx.capture(
              hefty do
                cs1 = User.changeset(%{name: "Alice"})
                _ <- EctoFx.change(:insert, cs1)
                cs2 = User.changeset(%{name: "Bob"})
                _ <- EctoFx.change(:insert, cs2)
                return(:done)
              end
            )

          return({result, changes})
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:ok, {:done, changes}} = outcome.result
      assert length(changes.inserts) == 2
      assert changes.updates == []
      assert changes.deletes == []

      [cs1, cs2] = changes.inserts
      assert Ecto.Changeset.get_field(cs1, :name) == "Alice"
      assert Ecto.Changeset.get_field(cs2, :name) == "Bob"
    end

    test "captures update changes" do
      user = %User{id: "123", name: "Old Name"}

      comp =
        hefty do
          {result, changes} <-
            EctoFx.capture(
              hefty do
                cs = User.changeset(user, %{name: "New Name"})
                _ <- EctoFx.change(:update, cs)
                return(:updated)
              end
            )

          return({result, changes})
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:ok, {:updated, changes}} = outcome.result
      assert changes.inserts == []
      assert length(changes.updates) == 1
      assert changes.deletes == []
    end

    test "captures delete changes" do
      user = %User{id: "456", name: "To Delete"}

      comp =
        hefty do
          {result, changes} <-
            EctoFx.capture(
              hefty do
                cs = User.changeset(user, %{})
                _ <- EctoFx.change(:delete, cs)
                return(:deleted)
              end
            )

          return({result, changes})
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:ok, {:deleted, changes}} = outcome.result
      assert changes.inserts == []
      assert changes.updates == []
      assert length(changes.deletes) == 1
    end

    test "captures mixed operations" do
      comp =
        hefty do
          {result, changes} <-
            EctoFx.capture(
              hefty do
                _ <- EctoFx.change(:insert, User.changeset(%{name: "New User"}))

                _ <-
                  EctoFx.change(:update, User.changeset(%User{id: "1"}, %{name: "Updated"}))

                _ <- EctoFx.change(:delete, User.changeset(%User{id: "2"}, %{}))
                _ <- EctoFx.change(:insert, Order.changeset(%{total: 100}))
                return(:mixed)
              end
            )

          return({result, changes})
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:ok, {:mixed, changes}} = outcome.result
      assert length(changes.inserts) == 2
      assert length(changes.updates) == 1
      assert length(changes.deletes) == 1
    end

    test "works with FxList.fx_map" do
      users = [
        %{name: "Alice"},
        %{name: "Bob"},
        %{name: "Charlie"}
      ]

      comp =
        hefty do
          {results, changes} <-
            EctoFx.capture(
              FxList.fx_map(users, fn attrs ->
                hefty do
                  cs = User.changeset(attrs)
                  _ <- EctoFx.change(:insert, cs)
                  return(attrs.name)
                end
              end)
            )

          return({results, changes})
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> FxList.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:ok, {["Alice", "Bob", "Charlie"], changes}} = outcome.result
      assert length(changes.inserts) == 3
    end

    test "discards changes on throw" do
      comp =
        hefty do
          {result, changes} <-
            EctoFx.capture(
              hefty do
                _ <- EctoFx.change(:insert, User.changeset(%{name: "Will be discarded"}))
                _ <- Throw.throw_error(:oops)
                return(:never_reached)
              end
            )

          return({result, changes})
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:error, :oops} = outcome.result
    end

    test "raises error on nested capture" do
      comp =
        hefty do
          {_result, _changes} <-
            EctoFx.capture(
              hefty do
                {_inner_result, _inner_changes} <-
                  EctoFx.capture(
                    hefty do
                      return(:inner)
                    end
                  )

                return(:outer)
              end
            )

          return(:done)
        end

      assert_raise ArgumentError, ~r/nested captures not supported/, fn ->
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()
      end
    end

    test "change outside capture raises error" do
      comp =
        con [EctoFx] do
          EctoFx.change(:insert, User.changeset(%{name: "Alice"}))
        end

      assert_raise RuntimeError, ~r/outside of EctoFx.capture/, fn ->
        comp
        |> EctoFx.TestHandler.run()
        |> Run.run()
      end
    end
  end

  # ============================================================================
  # Transaction Tests
  # ============================================================================

  describe "Ecto.transaction/2" do
    test "transaction wraps computation" do
      comp =
        hefty do
          result <-
            EctoFx.transaction(
              hefty do
                user <- EctoFx.insert(User.changeset(%{name: "Alice"}))
                return(user)
              end
            )

          return(result)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:ok, %User{name: "Alice"}} = outcome.result

      # Verify transaction operations were recorded
      state = outcome.outputs[EctoFx.TestHandler]
      ops = EctoFx.TestHandler.get_operations(state)

      op_types = Enum.map(ops, &op_type/1)
      assert :begin_transaction in op_types
      assert :insert in op_types
      assert :commit_transaction in op_types
    end

    test "transaction rolls back on throw" do
      comp =
        hefty do
          result <-
            EctoFx.transaction(
              hefty do
                _ <- EctoFx.insert(User.changeset(%{name: "Alice"}))
                _ <- Throw.throw_error(:rollback_me)
                return(:never_reached)
              end
            )

          return(result)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:error, :rollback_me} = outcome.result

      # Verify rollback was recorded
      state = outcome.outputs[EctoFx.TestHandler]
      ops = EctoFx.TestHandler.get_operations(state)

      op_types = Enum.map(ops, &op_type/1)
      assert :begin_transaction in op_types
      assert :rollback_transaction in op_types
      refute :commit_transaction in op_types
    end

    test "nested transactions raise error" do
      comp =
        hefty do
          result <-
            EctoFx.transaction(
              hefty do
                inner_result <-
                  EctoFx.transaction(
                    hefty do
                      return(:inner)
                    end
                  )

                return(inner_result)
              end
            )

          return(result)
        end

      assert_raise RuntimeError, ~r/Nested transactions/, fn ->
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()
      end
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration: capture inside transaction" do
    test "capture works inside transaction" do
      comp =
        hefty do
          result <-
            EctoFx.transaction(
              hefty do
                {processed, changes} <-
                  EctoFx.capture(
                    hefty do
                      _ <- EctoFx.change(:insert, User.changeset(%{name: "Alice"}))
                      _ <- EctoFx.change(:insert, User.changeset(%{name: "Bob"}))
                      return(:done)
                    end
                  )

                # Apply captured changes
                {count, _} <- EctoFx.insert_all(User, EctoFx.to_entries(changes.inserts))

                return({processed, count})
              end
            )

          return(result)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:ok, {:done, 2}} = outcome.result
    end

    test "transaction with queries and mutations" do
      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query(SampleQueries, :fetch_user, %{id: 1}, %User{
          id: "1",
          name: "Existing User"
        })

      comp =
        hefty do
          result <-
            EctoFx.transaction(
              hefty do
                user <- EctoFx.query(SampleQueries, :fetch_user, %{id: 1})
                updated <- EctoFx.update(User.changeset(user, %{name: "Updated User"}))
                return(updated)
              end
            )

          return(result)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run(state)
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:ok, %User{name: "Updated User"}} = outcome.result
    end
  end

  # ============================================================================
  # Helper Function Tests
  # ============================================================================

  describe "to_entries/1" do
    test "converts changesets to maps" do
      changesets = [
        User.changeset(%{name: "Alice", email: "alice@test.com"}),
        User.changeset(%{name: "Bob", email: "bob@test.com"})
      ]

      entries = EctoFx.to_entries(changesets)

      assert length(entries) == 2
      assert Enum.all?(entries, &is_map/1)
      assert Enum.at(entries, 0).name == "Alice"
      assert Enum.at(entries, 1).name == "Bob"
      refute Map.has_key?(Enum.at(entries, 0), :__meta__)
    end

    test "returns empty list for empty input" do
      assert EctoFx.to_entries([]) == []
    end
  end

  describe "group_by_schema/1" do
    test "groups changesets by schema" do
      changesets = [
        User.changeset(%{name: "Alice"}),
        Order.changeset(%{total: 100}),
        User.changeset(%{name: "Bob"}),
        Order.changeset(%{total: 200})
      ]

      grouped = EctoFx.group_by_schema(changesets)

      assert map_size(grouped) == 2
      assert length(grouped[User]) == 2
      assert length(grouped[Order]) == 2
    end

    test "returns empty map for empty input" do
      assert EctoFx.group_by_schema([]) == %{}
    end
  end

  describe "group_all_by_schema/1" do
    test "groups all captured changes by schema" do
      changes = %{
        inserts: [
          User.changeset(%{name: "New User"}),
          Order.changeset(%{total: 100})
        ],
        updates: [
          User.changeset(%User{id: "1"}, %{name: "Updated"})
        ],
        deletes: [
          Order.changeset(%Order{id: "2"}, %{})
        ]
      }

      grouped = EctoFx.group_all_by_schema(changes)

      assert map_size(grouped) == 2

      assert length(grouped[User].inserts) == 1
      assert length(grouped[User].updates) == 1
      assert grouped[User].deletes == []

      assert length(grouped[Order].inserts) == 1
      assert grouped[Order].updates == []
      assert length(grouped[Order].deletes) == 1
    end

    test "handles empty changes" do
      changes = %{inserts: [], updates: [], deletes: []}
      grouped = EctoFx.group_all_by_schema(changes)
      assert grouped == %{}
    end
  end

  # ============================================================================
  # Operation Tracking Tests
  # ============================================================================

  describe "TestHandler.get_operations/1" do
    test "tracks all operations in order" do
      user = %User{id: "789", name: "Eve", email: "eve@test.com"}
      insert_cs = User.changeset(%{name: "New User"})
      update_cs = User.changeset(user, %{name: "Updated Eve"})

      comp =
        con [EctoFx] do
          _ <- EctoFx.insert(insert_cs)
          _ <- EctoFx.update(update_cs)
          EctoFx.delete(user)
        end

      outcome =
        comp
        |> EctoFx.TestHandler.run()
        |> Run.run()

      state = outcome.outputs[EctoFx.TestHandler]
      ops = EctoFx.TestHandler.get_operations(state)

      assert length(ops) == 3
      assert %EctoFx.Insert{} = Enum.at(ops, 0)
      assert %EctoFx.Update{} = Enum.at(ops, 1)
      assert %EctoFx.Delete{} = Enum.at(ops, 2)
    end
  end

  # Helper to get operation type
  defp op_type(%EctoFx.Query{}), do: :query
  defp op_type(%EctoFx.Insert{}), do: :insert
  defp op_type(%EctoFx.Update{}), do: :update
  defp op_type(%EctoFx.Delete{}), do: :delete
  defp op_type(%EctoFx.InsertOrUpdate{}), do: :insert_or_update
  defp op_type(%EctoFx.InsertAll{}), do: :insert_all
  defp op_type(%EctoFx.UpdateAll{}), do: :update_all
  defp op_type(%EctoFx.DeleteAll{}), do: :delete_all
  defp op_type(%EctoFx.Change{}), do: :change
  defp op_type(%EctoFx.BeginTransaction{}), do: :begin_transaction
  defp op_type(%EctoFx.CommitTransaction{}), do: :commit_transaction
  defp op_type(%EctoFx.RollbackTransaction{}), do: :rollback_transaction
  defp op_type(%EctoFx.BeginCapture{}), do: :begin_capture
  defp op_type(%EctoFx.FinishCapture{}), do: :finish_capture
end
