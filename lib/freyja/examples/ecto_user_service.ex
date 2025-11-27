if Code.ensure_loaded?(Ecto) do
  defmodule Freyja.Examples.EctoUserService do
    @moduledoc """
    Example demonstrating how to build a domain service using `EctoFx` effects,
    and how to test it with `EctoFx.TestHandler` without needing a real database.

    ## The Pattern

    1. **Define Ecto schemas** with changesets as normal
    2. **Define query modules** that return Ecto queries (or results)
    3. **Write domain logic** using `EctoFx` effects for queries and mutations
    4. **Test with `TestHandler`** - stub queries and mutations, verify behavior

    ## Why This Matters

    Traditional Ecto code tightly couples domain logic to the database:

        def create_user_with_profile(attrs) do
          Repo.transaction(fn ->
            user = Repo.insert!(User.changeset(attrs))
            profile = Repo.insert!(Profile.changeset(user, attrs))
            {user, profile}
          end)
        end

    This is hard to test without a database. With EctoFx:

        defhefty create_user_with_profile(attrs) do
          user <- EctoFx.insert(User.changeset(attrs))
          profile <- EctoFx.insert(Profile.changeset(user, attrs))
          return({user, profile})
        end

    Now you can test with `TestHandler` - no database needed!

    ## Example Usage

        # In tests - no database!
        outcome = (
          UserService.register_user(%{name: "Alice", email: "alice@example.com"})
          |> EctoFx.TestHandler.run()
          |> Throw.Handler.run()
          |> Run.run()
        )

        assert {:ok, %User{name: "Alice"}} = outcome.result

        # In production - real database
        outcome = (
          UserService.register_user(%{name: "Alice", email: "alice@example.com"})
          |> EctoFx.Handler.run(MyApp.Repo, query_registry)
          |> Throw.Handler.run()
          |> Run.run()
        )
    """

    use Freyja.Syntax

    alias Freyja.Effects.{EctoFx, Lift, Throw}

    # ============================================================================
    # Ecto Schemas
    # ============================================================================

    defmodule User do
      @moduledoc "User schema with validation"
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      embedded_schema do
        field(:name, :string)
        field(:email, :string)
        field(:status, :string, default: "pending")
        timestamps()
      end

      def changeset(user \\ %__MODULE__{}, attrs) do
        user
        |> Ecto.Changeset.cast(attrs, [:name, :email, :status])
        |> Ecto.Changeset.validate_required([:name, :email])
        |> Ecto.Changeset.validate_format(:email, ~r/@/)
      end

      def activate_changeset(user) do
        Ecto.Changeset.change(user, status: "active")
      end
    end

    defmodule Profile do
      @moduledoc "User profile schema"
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      embedded_schema do
        field(:user_id, :binary_id)
        field(:bio, :string)
        field(:avatar_url, :string)
        timestamps()
      end

      def changeset(profile \\ %__MODULE__{}, user, attrs) do
        profile
        |> Ecto.Changeset.cast(attrs, [:bio, :avatar_url])
        |> Ecto.Changeset.put_change(:user_id, user.id)
      end
    end

    # ============================================================================
    # Query Module
    # ============================================================================

    defmodule Queries do
      @moduledoc """
      Query functions for the user service.

      In production, these would return Ecto queries or call Repo directly.
      With EctoFx, they're dispatched through the Query effect.
      """

      def find_user_by_email(%{email: _email}) do
        # In real code: Repo.get_by(User, email: email)
        # With EctoFx, this is handled by the registry/handler
        :handled_by_registry
      end

      def find_user_by_id(%{id: _id}) do
        :handled_by_registry
      end

      def list_active_users(%{limit: _limit}) do
        :handled_by_registry
      end
    end

    # ============================================================================
    # Domain Service Functions
    # ============================================================================

    @doc """
    Register a new user with a profile.

    Uses EctoFx effects for:
    - Checking if email is already taken (query)
    - Inserting the user (mutation)
    - Inserting the profile (mutation)

    All wrapped in a transaction for atomicity.
    """
    defhefty register_user(attrs) do
      # Check if email already exists
      existing <- EctoFx.query(Queries, :find_user_by_email, %{email: attrs.email})

      result <-
        case existing do
          nil ->
            # Email not taken - create user and profile in transaction
            EctoFx.transaction(
              hefty do
                user <- EctoFx.insert(User.changeset(attrs))
                profile <- EctoFx.insert(Profile.changeset(user, attrs))
                return({user, profile})
              end
            )

          _user ->
            # Email already taken - return error via Throw
            Throw.throw_error({:email_taken, attrs.email})
        end

      return(result)
    end

    @doc """
    Activate a user account.

    Finds the user by ID and updates their status to "active".
    """
    defhefty activate_user(user_id) do
      user <- EctoFx.query(Queries, :find_user_by_id, %{id: user_id})

      result <-
        case user do
          nil ->
            Throw.throw_error({:user_not_found, user_id})

          user ->
            hefty do
              updated <- EctoFx.update(User.activate_changeset(user))
              return(updated)
            end
        end

      return(result)
    end

    @doc """
    Update a user's profile.
    """
    defhefty update_profile(user_id, profile_attrs) do
      user <- EctoFx.query(Queries, :find_user_by_id, %{id: user_id})

      result <-
        case user do
          nil ->
            Throw.throw_error({:user_not_found, user_id})

          %{profile: nil} ->
            # No profile yet - create one
            hefty do
              profile <- EctoFx.insert(Profile.changeset(user, profile_attrs))
              return(profile)
            end

          %{profile: profile} ->
            # Update existing profile
            hefty do
              updated <- EctoFx.update(Profile.changeset(profile, user, profile_attrs))
              return(updated)
            end
        end

      return(result)
    end

    @doc """
    Deactivate multiple users by updating their status.

    Demonstrates bulk operations with FxList.fx_map.
    """
    defhefty deactivate_users(user_ids) do
      results <-
        Freyja.Effects.FxList.fx_map(user_ids, fn user_id ->
          hefty do
            user <- EctoFx.query(Queries, :find_user_by_id, %{id: user_id})

            result <-
              case user do
                nil ->
                  return({:error, :not_found})

                user ->
                  hefty do
                    changeset = Ecto.Changeset.change(user, status: "inactive")
                    updated <- EctoFx.update(changeset)
                    return({:ok, updated})
                  end
              end

            return(result)
          end
        end)

      return(results)
    end

    # ============================================================================
    # Builder Functions for Running
    # ============================================================================

    @doc """
    Build a test pipeline using TestHandler (no database needed).

    ## IEx Example

    Copy and paste the following into IEx:

        alias Freyja.Examples.EctoUserService

        # Register a new user (email not taken - TestHandler returns nil by default)
        outcome = (
          EctoUserService.register_user(%{name: "Alice", email: "alice@test.com"})
          |> EctoUserService.test_builder()
          |> Freyja.Run.run()
        )

        # Check the result - user and profile created
        {:ok, {user, profile}} = outcome.result
        user.name      # => "Alice"
        user.email     # => "alice@test.com"
        profile.user_id == user.id  # => true

    With stubbed queries to simulate existing user:

        alias Freyja.Examples.EctoUserService
        alias Freyja.Effects.EctoFx

        # Stub the query to return an existing user
        existing_user = %EctoUserService.User{
          id: "existing-id",
          name: "Existing",
          email: "alice@test.com"
        }

        state = (
          EctoFx.TestHandler.new()
          |> EctoFx.TestHandler.stub_query(
               EctoUserService.Queries,
               :find_user_by_email,
               %{email: "alice@test.com"},
               existing_user
             )
        )

        outcome = (
          EctoUserService.register_user(%{name: "Alice", email: "alice@test.com"})
          |> EctoUserService.test_builder(state)
          |> Freyja.Run.run()
        )

        # Email was taken - returns error
        outcome.result  # => {:error, {:email_taken, "alice@test.com"}}
    """
    def test_builder(computation, test_handler_state \\ EctoFx.TestHandler.new()) do
      alias Freyja.Effects.{Lift, Throw, FxList}

      computation
      |> EctoFx.TestHandler.run(test_handler_state)
      |> Lift.Algebra.run()
      |> FxList.Algebra.run()
      |> Throw.Handler.run()
    end

    @doc """
    Build a production pipeline using real Handler (requires database).

    ## Example

    This requires a real Ecto Repo and database connection:

        alias Freyja.Examples.EctoUserService

        outcome = (
          EctoUserService.register_user(%{name: "Alice", email: "alice@test.com"})
          |> EctoUserService.prod_builder(MyApp.Repo, %{EctoUserService.Queries => :direct})
          |> Freyja.Run.run()
        )
    """
    def prod_builder(computation, repo, query_registry \\ %{}) do
      alias Freyja.Effects.{Lift, Throw, FxList}

      computation
      |> EctoFx.Handler.run(repo, query_registry)
      |> Lift.Algebra.run()
      |> FxList.Algebra.run()
      |> Throw.Handler.run()
    end
  end
end
