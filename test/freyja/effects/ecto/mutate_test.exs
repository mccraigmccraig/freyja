defmodule Freyja.Effects.Ecto.MutateTest do
  use ExUnit.Case, async: true

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.Ecto.Mutate
  alias Freyja.Effects.Throw
  alias Freyja.Run

  # Simple schema for testing
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

  describe "Mutate.TestHandler" do
    test "insert with valid changeset returns applied changes" do
      changeset = User.changeset(%{name: "Alice", email: "alice@test.com"})

      comp =
        con [Mutate] do
          Mutate.insert(changeset)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run()
        |> Run.run()

      assert %User{name: "Alice", email: "alice@test.com"} = outcome.result
    end

    test "insert with invalid changeset returns error via Throw" do
      changeset = User.changeset(%{email: "no-name@test.com"})
      # name is required, so this should fail

      comp =
        con [Mutate] do
          Mutate.insert(changeset)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run()
        |> Throw.Handler.run()
        |> Run.run()

      assert {:error, {:changeset_error, %Ecto.Changeset{valid?: false}}} = outcome.result
    end

    test "update with valid changeset returns updated struct" do
      user = %User{id: "123", name: "Bob", email: "bob@test.com"}
      changeset = User.changeset(user, %{name: "Robert"})

      comp =
        con [Mutate] do
          Mutate.update(changeset)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run()
        |> Run.run()

      assert %User{id: "123", name: "Robert", email: "bob@test.com"} = outcome.result
    end

    test "delete returns the deleted struct" do
      user = %User{id: "456", name: "Charlie", email: "charlie@test.com"}

      comp =
        con [Mutate] do
          Mutate.delete(user)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run()
        |> Run.run()

      assert %User{id: "456", name: "Charlie"} = outcome.result
    end

    test "insert_or_update with valid changeset succeeds" do
      changeset = User.changeset(%{name: "Dana", email: "dana@test.com"})

      comp =
        con [Mutate] do
          Mutate.insert_or_update(changeset)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run()
        |> Run.run()

      assert %User{name: "Dana", email: "dana@test.com"} = outcome.result
    end

    test "insert_all returns count" do
      entries = [
        %{name: "User1", email: "u1@test.com"},
        %{name: "User2", email: "u2@test.com"},
        %{name: "User3", email: "u3@test.com"}
      ]

      comp =
        con [Mutate] do
          Mutate.insert_all(User, entries)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run()
        |> Run.run()

      assert {3, nil} = outcome.result
    end

    test "tracks all mutations in state" do
      user = %User{id: "789", name: "Eve", email: "eve@test.com"}
      insert_cs = User.changeset(%{name: "New User"})
      update_cs = User.changeset(user, %{name: "Updated Eve"})

      comp =
        con [Mutate] do
          _ <- Mutate.insert(insert_cs)
          _ <- Mutate.update(update_cs)
          Mutate.delete(user)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run()
        |> Run.run()

      state = outcome.outputs[Mutate.TestHandler]
      mutations = Mutate.TestHandler.get_mutations(state)

      assert length(mutations) == 3
      assert %Mutate.Insert{} = Enum.at(mutations, 0)
      assert %Mutate.Update{} = Enum.at(mutations, 1)
      assert %Mutate.Delete{} = Enum.at(mutations, 2)
    end

    test "custom stubs override default behavior" do
      changeset = User.changeset(%{name: "Frank"})

      state =
        Mutate.TestHandler.new()
        |> Mutate.TestHandler.stub_insert(User, fn _cs ->
          {:ok, %User{id: "custom-id", name: "Stubbed Frank", email: "stubbed@test.com"}}
        end)

      comp =
        con [Mutate] do
          Mutate.insert(changeset)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run(state)
        |> Run.run()

      assert %User{id: "custom-id", name: "Stubbed Frank"} = outcome.result
    end

    test "stub can return errors" do
      changeset = User.changeset(%{name: "George"})

      error_changeset =
        changeset
        |> Ecto.Changeset.add_error(:email, "is required by stub")

      state =
        Mutate.TestHandler.new()
        |> Mutate.TestHandler.stub_insert(User, fn _cs ->
          {:error, error_changeset}
        end)

      comp =
        con [Mutate] do
          Mutate.insert(changeset)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run(state)
        |> Throw.Handler.run()
        |> Run.run()

      assert {:error, {:changeset_error, cs}} = outcome.result
      assert "is required by stub" in errors_on(cs).email
    end
  end

  describe "multiple operations in sequence" do
    test "chain of mutations" do
      comp =
        con [Mutate] do
          user <- Mutate.insert(User.changeset(%{name: "Initial"}))
          updated <- Mutate.update(User.changeset(user, %{name: "Updated"}))
          return(updated)
        end

      outcome =
        comp
        |> Mutate.TestHandler.run()
        |> Run.run()

      assert %User{name: "Updated"} = outcome.result
    end
  end

  # Helper to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
