defmodule Freyja.Examples.ChangeCapture do
  @moduledoc """
  Example demonstrating a real-world effectful processing scenario using
  tagged effects for change capture and bulk updates.

  This example shows:
  - Storage effect for querying and updating records
  - TaggedWriter for capturing changes during processing
  - List effect for mapping over collections
  - State effect for counting processed records
  - Using `listen` to capture changes and apply them in bulk

  ## Scenario

  Process a collection of User records:
  1. Query users from storage
  2. Map over each user, removing email fields
  3. Track each change with TaggedWriter
  4. Count processed records with State
  5. Use `listen` to capture all changes
  6. Apply changes in a single bulk update operation

  This pattern is useful for:
  - Audit logging with bulk commits
  - Batch database updates
  - Change tracking and replay
  - Optimistic locking with conflict detection
  """

  import Freyja.Sig.DefEffectStruct
  import Freyja.Con

  alias Freyja.Effects.State
  alias Freyja.Effects.List
  alias Freyja.Effects.TaggedWriter

  # Storage Effect Definition
  defmodule Storage do
    @moduledoc """
    Storage effect for querying and updating records.

    Operations:
    - `query(ids)` - Retrieve records by IDs
    - `change(old, new)` - Record a change (writes to TaggedWriter)
    - `update_all(changes)` - Apply a list of changes in bulk
    """

    import Freyja.Sig.DefEffectStruct

    def_effect_struct(Query, ids: [])
    def_effect_struct(Change, old: nil, new: nil)
    def_effect_struct(UpdateAll, changes: [])
    def_effect_struct(ListenForChanges, computation: nil)

    @doc "Query records by IDs"
    def query(ids), do: %Query{ids: ids}

    @doc """
    Record a change from old record to new record.
    Writes the change to the :changes tag in TaggedWriter.
    """
    def change(old, new), do: %Change{old: old, new: new}

    @doc """
    Apply a list of changes in a single bulk operation.
    Returns the number of records updated.
    """
    def update_all(changes), do: %UpdateAll{changes: changes}

    def listen_for_changes(computation), do: %ListenForChanges{computation: computation}
  end

  # Storage Handler for Users
  defmodule Storage.Handler do
    @moduledoc """
    Example handler for Storage effect managing User records.

    Handler state is a map of user_id => user_record.
    """

    alias Freyja.Freer
    alias Freyja.Freer.Impl
    alias Freyja.Freer.Impure
    alias Freyja.Examples.ChangeCapture.Storage
    alias Freyja.Examples.ChangeCapture.Storage.Query
    alias Freyja.Examples.ChangeCapture.Storage.Change
    alias Freyja.Examples.ChangeCapture.Storage.UpdateAll
    alias Freyja.Examples.ChangeCapture.Storage.ListenForChanges
    alias Freyja.Effects.TaggedWriter
    alias Freyja.Run.RunState

    @behaviour Freyja.EffectHandler

    @impl Freyja.EffectHandler
    def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
      sig == Storage
    end

    @impl Freyja.EffectHandler
    def interpret(
          %Freer.Impure{sig: Storage, data: operation, q: q} = _computation,
          _handler_key,
          state,
          %RunState{} = _run_state
        ) do
      case operation do
        %Query{ids: ids} ->
          # Query records by IDs
          records = Enum.map(ids, fn id -> Map.get(state, id) end) |> Enum.filter(&(&1 != nil))
          {Impl.q_apply(q, records), state}

        %Change{old: old, new: new} ->
          # Record a change by writing to TaggedWriter
          # This doesn't modify storage state yet - just logs the change
          # Use bindp to preserve the continuation queue
          tell_computation = TaggedWriter.tell(:changes, {old, new})
          {Impl.bindp(tell_computation, q), state}

        %UpdateAll{changes: changes} ->
          # Apply all changes in bulk
          updated_state =
            Enum.reduce(changes, state, fn {old, new}, acc ->
              # Find the old record and replace with new
              if old.id do
                Map.put(acc, old.id, new)
              else
                acc
              end
            end)

          # Return count of changes applied
          {Impl.q_apply(q, length(changes)), updated_state}

        %ListenForChanges{computation: computation} ->
          list_update_comp =
            con do
              {result, all_logs} <- TaggedWriter.listen(computation)
              changes = all_logs[:changes] || []
              Storage.update_all(changes)
              return({result, all_logs})
            end

          {Impl.bindp(list_update_comp, q), state}
      end
    end
  end

  # Example: Remove email from users with change tracking
  defcon remove_email_from_user(user) do
    # Create new user without email
    updated_user = Map.delete(user, :email)

    # Record the change
    Storage.change(user, updated_user)

    # Increment processed count
    State.update(&(&1 + 1))

    return(updated_user)
  end

  defcon process_users(user_ids), [List, TaggedWriter] do
    # Query users from storage
    users <- Storage.query(user_ids)

    # Process users with change tracking
    # Use listen to capture all changes made during the map
    {updated_users, all_logs} <-
      Storage.listen_for_changes(fx_map(users, &remove_email_from_user/1))

    captured_changes = all_logs[:changes] || []

    # Get final count of processed records
    processed_count <- State.get()

    return(%{
      updated_users: updated_users,
      captured_changes: captured_changes,
      processed_count: processed_count,
      update_count: Enum.count(captured_changes)
    })
  end

  # More complex example: Conditional updates with validation
  defcon validate_and_update_user(user), [TaggedWriter] do
    # Only remove email if it's a test email
    is_test_email = String.ends_with?(user.email || "", "@test.com")

    updated_user <-
      if is_test_email do
        con do
          new_user = Map.put(user, :email, nil)
          Storage.change(user, new_user)
          tell(:validations, {:removed_test_email, user.id})
          return(new_user)
        end
      else
        con do
          tell(:validations, {:kept_email, user.id})
          return(user)
        end
      end

    # Increment processed count
    State.update(&(&1 + 1))

    return(updated_user)
  end

  defcon process_users_with_validation(user_ids), [List, TaggedWriter] do
    # Query users
    users <- Storage.query(user_ids)

    # Process with both change and validation tracking
    {updated_users, all_logs} <-
      Storage.listen_for_changes(fx_map(users, &validate_and_update_user/1))

    # Extract the specific logs we care about
    captured_changes = all_logs[:changes] || []
    validation_results = all_logs[:validations] || []

    # Get processed count
    processed_count <- State.get()

    return(%{
      updated_users: updated_users,
      changes_applied: Enum.count(captured_changes),
      processed_count: processed_count,
      validations: validation_results
    })
  end

  # Example: Multi-stage processing with multiple listen scopes
  defcon anonymize_user(user) do
    # Remove PII fields
    anonymized = %{
      id: user.id,
      created_at: user.created_at
      # email, name removed
    }

    Storage.change(user, anonymized)

    State.update(&(&1 + 1))

    return(anonymized)
  end

  defcon audit_user(user), [TaggedWriter] do
    # Log audit trail
    tell(:audit, %{action: :reviewed, user_id: user.id, timestamp: System.system_time()})

    State.update(&(&1 + 1))

    return(user)
  end

  defcon multi_stage_process(user_ids), [List, TaggedWriter] do
    users <- Storage.query(user_ids)

    # Stage 1: Anonymization with change capture
    {anonymized_users, stage1_logs} <-
      Storage.listen_for_changes(fx_map(users, &anonymize_user/1))

    anonymize_changes = stage1_logs[:changes] || []
    tell(:stages, {:anonymization_complete, length(anonymize_changes)})

    # Stage 2: Audit trail
    {_audited_users, stage2_logs} <-
      listen(fx_map(anonymized_users, &audit_user/1))

    audit_logs = stage2_logs[:audit] || []
    tell(:stages, {:audit_complete, length(audit_logs)})

    # Get final counts
    total_processed <- State.get()
    all_stages <- peek(:stages)

    return(%{
      anonymized: length(anonymize_changes),
      audited: length(audit_logs),
      total_processed: total_processed,
      stages: all_stages
    })
  end
end
