if Code.ensure_loaded?(Ecto) do
  defmodule Freyja.Examples.EctoChangeCapture do
    @moduledoc """
    Example demonstrating change capture with Ecto changesets using `EctoFx`.

    ## The Pattern

    The `EctoFx.capture/1` higher-order effect allows you to:

    1. Process records individually with simple, focused functions
    2. Capture all intended changes without executing them
    3. Review/validate the captured changes
    4. Apply them in bulk for efficiency

    This separates the "what to change" logic from "how to persist" concerns.

    ## Use Cases

    - **Batch processing**: Process 1000 users individually, but INSERT/UPDATE in bulk
    - **Dry-run mode**: Capture changes without applying them, show what would change
    - **Audit logging**: Record exactly what changes were intended before applying
    - **Validation**: Validate the entire batch before committing any changes
    - **Testing**: Verify change logic without touching the database

    ## Example

        # Process users and capture changes
        {results, changes} =
          EctoChangeCapture.process_users_with_capture(user_ids)
          |> EctoFx.TestHandler.run()
          |> Lift.Algebra.run()
          |> Throw.Handler.run()
          |> Run.run()
          |> Map.get(:result)

        # changes is a map with :inserts, :updates, :deletes lists
        # Each list contains Ecto.Changeset structs ready for bulk operations

        # Apply in bulk (in production)
        Repo.insert_all(User, EctoFx.to_entries(changes.inserts))
    """

    use Freyja.Syntax

    alias Freyja.Effects.{EctoFx, Lift, Throw, FxList, State}

    # ============================================================================
    # Ecto Schemas
    # ============================================================================

    defmodule User do
      @moduledoc "User schema for change capture example"
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      embedded_schema do
        field(:name, :string)
        field(:email, :string)
        field(:status, :string, default: "active")
        field(:anonymized_at, :utc_datetime)
        timestamps()
      end

      def changeset(user \\ %__MODULE__{}, attrs) do
        user
        |> Ecto.Changeset.cast(attrs, [:name, :email, :status, :anonymized_at])
        |> Ecto.Changeset.validate_required([:name, :email])
      end

      def anonymize_changeset(user) do
        user
        |> Ecto.Changeset.change(%{
          email: nil,
          name: "Anonymous",
          status: "anonymized",
          anonymized_at: DateTime.utc_now()
        })
      end

      def deactivate_changeset(user) do
        Ecto.Changeset.change(user, status: "inactive")
      end
    end

    defmodule AuditLog do
      @moduledoc "Audit log entry schema"
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      embedded_schema do
        field(:user_id, :binary_id)
        field(:action, :string)
        field(:details, :map)
        timestamps()
      end

      def changeset(attrs) do
        %__MODULE__{}
        |> Ecto.Changeset.cast(attrs, [:user_id, :action, :details])
        |> Ecto.Changeset.validate_required([:user_id, :action])
      end
    end

    # ============================================================================
    # Query Module
    # ============================================================================

    defmodule Queries do
      @moduledoc "Query functions for the change capture example"

      def find_users_by_ids(%{ids: _ids}) do
        :handled_by_registry
      end

      def find_user_by_id(%{id: _id}) do
        :handled_by_registry
      end
    end

    # ============================================================================
    # Per-Record Processing Functions
    # ============================================================================
    #
    # These functions process individual records and can be passed to
    # FxList.fx_map. This demonstrates effect polymorphism - each function
    # uses whatever effects it needs, and they compose naturally with
    # EctoFx.capture/1.

    @doc """
    Anonymize a single user and record an audit log entry.

    Uses `EctoFx.Changes` to record:
    - An update change for the user anonymization
    - An insert change for the audit log entry

    Returns the anonymized user struct.
    """
    defhefty anonymize_user(user) do
      changeset = User.anonymize_changeset(user)

      # Record the change (captured, not persisted)
      _ <- EctoFx.Changes.update(changeset)

      # Also record an audit log entry
      audit_changeset =
        AuditLog.changeset(%{
          user_id: user.id,
          action: "anonymize",
          details: %{original_email: user.email}
        })

      _ <- EctoFx.Changes.insert(audit_changeset)

      # Return the result of applying the changeset
      return(Ecto.Changeset.apply_changes(changeset))
    end

    @doc """
    Process a user based on their status.

    - Active users are deactivated (update change)
    - Inactive users are deleted (delete change)
    - Other statuses are skipped (no change)

    Returns a tagged tuple indicating what action was taken.
    """
    defhefty process_user_by_status(user) do
      case user.status do
        "active" ->
          hefty do
            changeset = User.deactivate_changeset(user)
            _ <- EctoFx.Changes.update(changeset)
            return({:deactivated, Ecto.Changeset.apply_changes(changeset)})
          end

        "inactive" ->
          hefty do
            _ <- EctoFx.Changes.delete(Ecto.Changeset.change(user))
            return({:deleted, user})
          end

        _ ->
          return({:skipped, user})
      end
    end

    @doc """
    Create a user from attributes if valid.

    Records an insert change if the changeset is valid, otherwise
    returns an error tuple with the invalid changeset.
    """
    defhefty create_user_if_valid(attrs) do
      changeset = User.changeset(attrs)

      if changeset.valid? do
        hefty do
          _ <- EctoFx.Changes.insert(changeset)
          return({:ok, Ecto.Changeset.apply_changes(changeset)})
        end
      else
        return({:error, changeset})
      end
    end

    @doc """
    Deactivate a user and record the change.

    Simple processing function that records a single update change.
    """
    defhefty deactivate_user(user) do
      changeset = User.deactivate_changeset(user)
      _ <- EctoFx.Changes.update(changeset)
      return(:ok)
    end

    # ============================================================================
    # Change Capture Examples
    # ============================================================================

    @doc """
    Anonymize users and capture all changes without persisting.

    This demonstrates the core pattern:
    1. Query users
    2. Process each user with `anonymize_user/1`
    3. Capture changes via `EctoFx.capture/1`
    4. Return both processed results and captured changes

    The captured changes can then be:
    - Applied in bulk for efficiency
    - Validated before committing
    - Logged for audit purposes
    - Discarded (dry-run mode)

    ## IEx Example

    Copy and paste the following into IEx:

        alias Freyja.Examples.EctoChangeCapture
        alias Freyja.Examples.EctoChangeCapture.User

        # Create some test users
        users = %{
          "user-1" => %User{id: "user-1", name: "Alice", email: "alice@test.com", status: "active"},
          "user-2" => %User{id: "user-2", name: "Bob", email: "bob@test.com", status: "active"}
        }

        # Run the computation with test_builder (no real database needed!)
        outcome = (
          EctoChangeCapture.anonymize_users_with_capture(["user-1", "user-2"])
          |> EctoChangeCapture.test_builder(users)
          |> Freyja.Run.run()
        )

        # Unwrap the result
        {:ok, {anonymized_users, captured_changes}} = outcome.result

        # Check the anonymized users
        anonymized_users
        # => [%User{name: "Anonymous", email: nil, status: "anonymized", ...}, ...]

        # Check the captured changes - 2 updates (users) + 2 inserts (audit logs)
        length(captured_changes.updates)   # => 2
        length(captured_changes.inserts)   # => 2

        # Inspect a captured changeset
        hd(captured_changes.updates).changes
        # => %{email: nil, name: "Anonymous", status: "anonymized", anonymized_at: ...}
    """
    defhefty anonymize_users_with_capture(user_ids) do
      users <- EctoFx.query(Queries, :find_users_by_ids, %{ids: user_ids})

      # EctoFx.capture/1 wraps the computation and collects all EctoFx.change calls
      {anonymized_users, captured_changes} <-
        EctoFx.capture(FxList.fx_map(users, &anonymize_user/1))

      return({anonymized_users, captured_changes})
    end

    @doc """
    Process users with conditional changes based on status.

    Uses `process_user_by_status/1` which applies different logic based
    on each user's status field:
    - Active users are deactivated (update change)
    - Inactive users are deleted (delete change)
    - Other statuses are skipped (no change)

    ## IEx Example

    Copy and paste the following into IEx:

        alias Freyja.Examples.EctoChangeCapture
        alias Freyja.Examples.EctoChangeCapture.User

        # Mix of active and inactive users
        users = %{
          "user-1" => %User{id: "user-1", name: "Alice", email: "alice@test.com", status: "active"},
          "user-2" => %User{id: "user-2", name: "Bob", email: "bob@test.com", status: "inactive"},
          "user-3" => %User{id: "user-3", name: "Carol", email: "carol@test.com", status: "active"}
        }

        outcome = (
          EctoChangeCapture.process_users_conditionally(["user-1", "user-2", "user-3"])
          |> EctoChangeCapture.test_builder(users)
          |> Freyja.Run.run()
        )

        {:ok, result} = outcome.result

        # Check what happened to each user
        result.results
        # => [{:deactivated, %User{status: "inactive", ...}},
        #     {:deleted, %User{...}},
        #     {:deactivated, %User{status: "inactive", ...}}]

        # Check captured changes - 2 updates + 1 delete
        length(result.changes.updates)  # => 2 (deactivations)
        length(result.changes.deletes)  # => 1 (deletion)
    """
    defhefty process_users_conditionally(user_ids) do
      users <- EctoFx.query(Queries, :find_users_by_ids, %{ids: user_ids})

      {results, changes} <-
        EctoFx.capture(FxList.fx_map(users, &process_user_by_status/1))

      return(%{results: results, changes: changes})
    end

    @doc """
    Batch user creation with change capture.

    Uses `create_user_if_valid/1` to validate each set of attributes
    and capture insert changes only for valid users.

    ## IEx Example

    Copy and paste the following into IEx:

        alias Freyja.Examples.EctoChangeCapture

        # Mix of valid and invalid user attributes
        user_attrs = [
          %{name: "Alice", email: "alice@test.com"},      # valid
          %{name: "Bob", email: "bob@test.com"},          # valid
          %{name: "InvalidUser", email: nil}              # invalid - missing email
        ]

        outcome = (
          EctoChangeCapture.create_users_batch(user_attrs)
          |> EctoChangeCapture.test_builder()
          |> Freyja.Run.run()
        )

        {:ok, result} = outcome.result

        # Check successfully created users
        result.users
        # => [%User{name: "Alice", ...}, %User{name: "Bob", ...}]
        length(result.users)  # => 2

        # Check validation errors
        length(result.errors)  # => 1
        hd(result.errors).errors  # => [email: {"can't be blank", ...}]

        # Check captured changes - only valid users generate insert changes
        length(result.changes.inserts)  # => 2
    """
    defhefty create_users_batch(user_attrs_list) do
      {users, changes} <-
        EctoFx.capture(FxList.fx_map(user_attrs_list, &create_user_if_valid/1))

      # Separate successes and failures
      {successes, failures} =
        Enum.split_with(users, fn
          {:ok, _} -> true
          {:error, _} -> false
        end)

      return(%{
        users: Enum.map(successes, fn {:ok, u} -> u end),
        errors: Enum.map(failures, fn {:error, cs} -> cs end),
        changes: changes
      })
    end

    @doc """
    Process users within a transaction, capturing changes and persisting in bulk.

    This demonstrates the full pattern:
    1. Query users
    2. Process each user with simple per-record logic (capture changes)
    3. Apply inserts in bulk with `insert_all`
    4. Apply updates in bulk with `insert_all` using `on_conflict: :replace_all`

    All within a transaction for atomicity.
    """
    defhefty transactional_anonymize(user_ids) do
      result <-
        EctoFx.transaction(
          hefty do
            users <- EctoFx.query(Queries, :find_users_by_ids, %{ids: user_ids})

            # Capture all changes without persisting
            {anonymized, changes} <-
              EctoFx.capture(FxList.fx_map(users, &anonymize_user/1))

            # Persist inserts in bulk (audit logs)
            _ <- EctoFx.insert_all(AuditLog, EctoFx.to_entries(changes.inserts))

            # Persist updates in bulk using upsert
            # on_conflict: :replace_all replaces all fields on conflict with primary key
            _ <-
              EctoFx.insert_all(
                User,
                EctoFx.to_entries(changes.updates),
                on_conflict: :replace_all,
                conflict_target: [:id]
              )

            return({anonymized, changes})
          end
        )

      return(result)
    end

    @doc """
    Demonstrate using captured changes with EctoFx helper functions.

    Uses `deactivate_user/1` to process users, then shows how to
    work with the captured changes using helper functions.

    ## IEx Example

    Copy and paste the following into IEx:

        alias Freyja.Examples.EctoChangeCapture
        alias Freyja.Examples.EctoChangeCapture.User

        users = %{
          "user-1" => %User{id: "user-1", name: "Alice", email: "alice@test.com", status: "active"},
          "user-2" => %User{id: "user-2", name: "Bob", email: "bob@test.com", status: "active"}
        }

        outcome = (
          EctoChangeCapture.demonstrate_change_helpers(["user-1", "user-2"])
          |> EctoChangeCapture.test_builder(users)
          |> Freyja.Run.run()
        )

        {:ok, result} = outcome.result

        # Check counts
        result.update_count   # => 2
        result.insert_count   # => 0
        result.delete_count   # => 0

        # Check grouped changes by schema
        result.grouped_by_schema
        # => %{Freyja.Examples.EctoChangeCapture.User => [%Ecto.Changeset{}, ...]}

        # Access raw changes
        result.raw_changes.updates
        # => [%Ecto.Changeset{changes: %{status: "inactive"}, ...}, ...]
    """
    defhefty demonstrate_change_helpers(user_ids) do
      users <- EctoFx.query(Queries, :find_users_by_ids, %{ids: user_ids})

      {_processed, changes} <-
        EctoFx.capture(FxList.fx_map(users, &deactivate_user/1))

      # Use helper functions to work with captured changes
      # group_by_schema groups changesets by their schema module
      grouped = EctoFx.group_by_schema(changes.updates)

      # to_entries converts changesets to maps for insert_all
      # (only works for inserts, but showing the API)
      # entries = EctoFx.to_entries(changes.inserts)

      return(%{
        raw_changes: changes,
        grouped_by_schema: grouped,
        update_count: length(changes.updates),
        insert_count: length(changes.inserts),
        delete_count: length(changes.deletes)
      })
    end

    # ============================================================================
    # Builder Functions
    # ============================================================================

    @doc """
    Build a test pipeline with stubbed data.

    ## Example

        users = %{
          "user-1" => %User{id: "user-1", name: "Alice", email: "alice@test.com", status: "active"},
          "user-2" => %User{id: "user-2", name: "Bob", email: "bob@test.com", status: "inactive"}
        }

        outcome =
          EctoChangeCapture.test_builder(
            EctoChangeCapture.anonymize_users_with_capture(["user-1", "user-2"]),
            users
          )
          |> Run.run()

        {anonymized, changes} = outcome.result
    """
    def test_builder(computation, users \\ %{}) do
      state =
        EctoFx.TestHandler.new()
        |> stub_user_queries(users)

      computation
      |> EctoFx.TestHandler.run(state)
      |> Lift.Algebra.run()
      |> FxList.Algebra.run()
      |> Throw.Handler.run()
      |> State.Handler.run(0)
    end

    defp stub_user_queries(state, users) do
      # Stub find_users_by_ids to return users matching the IDs
      state
      |> EctoFx.TestHandler.stub_query_fn(Queries, :find_users_by_ids, fn %{ids: ids} ->
        ids
        |> Enum.map(&Map.get(users, &1))
        |> Enum.filter(& &1)
      end)
      |> EctoFx.TestHandler.stub_query_fn(Queries, :find_user_by_id, fn %{id: id} ->
        Map.get(users, id)
      end)
    end
  end
end
