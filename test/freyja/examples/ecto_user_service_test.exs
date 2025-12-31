defmodule Freyja.Examples.EctoUserServiceTest do
  use ExUnit.Case, async: true

  alias Freyja.Examples.EctoUserService
  alias Freyja.Examples.EctoUserService.Profile
  alias Freyja.Examples.EctoUserService.Queries
  alias Freyja.Examples.EctoUserService.User
  alias Freyja.Effects.EctoFx
  alias Freyja.Run

  describe "register_user/1" do
    test "creates user and profile when email is not taken" do
      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query(
          Queries,
          :find_user_by_email,
          %{email: "alice@example.com"},
          nil
        )

      outcome =
        EctoUserService.register_user(%{name: "Alice", email: "alice@example.com", bio: "Hello!"})
        |> EctoUserService.test_builder(state)
        |> Run.run()

      assert {:ok, {user, profile}} = outcome.result
      assert %User{name: "Alice", email: "alice@example.com"} = user
      assert %Profile{bio: "Hello!"} = profile
      assert profile.user_id == user.id
    end

    test "returns error when email is already taken" do
      existing_user = %User{id: "existing-id", name: "Bob", email: "taken@example.com"}

      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query(
          Queries,
          :find_user_by_email,
          %{email: "taken@example.com"},
          existing_user
        )

      outcome =
        EctoUserService.register_user(%{name: "Alice", email: "taken@example.com"})
        |> EctoUserService.test_builder(state)
        |> Run.run()

      assert {:error, {:email_taken, "taken@example.com"}} = outcome.result
    end

    test "returns changeset error when validation fails" do
      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query(Queries, :find_user_by_email, %{email: "invalid"}, nil)

      outcome =
        EctoUserService.register_user(%{name: "Alice", email: "invalid"})
        |> EctoUserService.test_builder(state)
        |> Run.run()

      assert {:error, {:changeset_error, %Ecto.Changeset{valid?: false}}} = outcome.result
    end
  end

  describe "activate_user/1" do
    test "activates an existing user" do
      user = %User{id: "user-1", name: "Alice", email: "alice@test.com", status: "pending"}

      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query(Queries, :find_user_by_id, %{id: "user-1"}, user)

      outcome =
        EctoUserService.activate_user("user-1")
        |> EctoUserService.test_builder(state)
        |> Run.run()

      assert {:ok, %User{id: "user-1", status: "active"}} = outcome.result
    end

    test "returns error when user not found" do
      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query(Queries, :find_user_by_id, %{id: "nonexistent"}, nil)

      outcome =
        EctoUserService.activate_user("nonexistent")
        |> EctoUserService.test_builder(state)
        |> Run.run()

      assert {:error, {:user_not_found, "nonexistent"}} = outcome.result
    end
  end

  describe "deactivate_users/1" do
    test "deactivates multiple users" do
      user1 = %User{id: "user-1", name: "Alice", email: "alice@test.com", status: "active"}
      user2 = %User{id: "user-2", name: "Bob", email: "bob@test.com", status: "active"}

      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query_fn(Queries, :find_user_by_id, fn
          %{id: "user-1"} -> user1
          %{id: "user-2"} -> user2
          %{id: _} -> nil
        end)

      outcome =
        EctoUserService.deactivate_users(["user-1", "user-2"])
        |> EctoUserService.test_builder(state)
        |> Run.run()

      assert {:ok, results} = outcome.result

      assert [
               {:ok, %User{id: "user-1", status: "inactive"}},
               {:ok, %User{id: "user-2", status: "inactive"}}
             ] = results
    end

    test "handles mix of found and not found users" do
      user1 = %User{id: "user-1", name: "Alice", email: "alice@test.com", status: "active"}

      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query_fn(Queries, :find_user_by_id, fn
          %{id: "user-1"} -> user1
          %{id: _} -> nil
        end)

      outcome =
        EctoUserService.deactivate_users(["user-1", "nonexistent"])
        |> EctoUserService.test_builder(state)
        |> Run.run()

      assert {:ok, results} = outcome.result

      assert [
               {:ok, %User{id: "user-1", status: "inactive"}},
               {:error, :not_found}
             ] = results
    end
  end

  describe "TestHandler operations tracking" do
    test "records all operations performed" do
      user = %User{id: "user-1", name: "Alice", email: "alice@test.com", status: "pending"}

      state =
        EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query(Queries, :find_user_by_id, %{id: "user-1"}, user)

      outcome =
        EctoUserService.activate_user("user-1")
        |> EctoUserService.test_builder(state)
        |> Run.run()

      # Get the handler state from outputs
      handler_state = outcome.outputs[EctoFx.TestHandler]
      operations = EctoFx.TestHandler.get_operations(handler_state)

      # Should have: query, update
      assert length(operations) == 2

      op_types =
        Enum.map(operations, fn
          %EctoFx.Query{} -> :query
          %EctoFx.Update{} -> :update
          _ -> :other
        end)

      assert op_types == [:query, :update]
    end
  end
end
