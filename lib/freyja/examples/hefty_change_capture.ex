defmodule Freyja.Examples.HeftyChangeCapture do
  @moduledoc """
  Example demonstrating real-world effectful processing using Hefty algebras.

  This is a reimplementation of ChangeCapture using Hefty higher-order effects,
  showcasing how to combine first-order and higher-order operations in a single
  effect signature.

  This example shows:
  - Storage effect with BOTH first-order and higher-order operations
  - First-order: `query`, `change`, `update_all` (handled by EffectHandler)
  - Higher-order: `apply_all_changes` (elaborated by Algebra)
  - HeftyTaggedWriter for capturing changes during processing
  - HeftyFxList for mapping over collections
  - State effect for counting processed records
  - Using Hefty algebras to elaborate higher-order operations

  ## Key Differences from Old ChangeCapture

  **Old approach (Freer scoped effects):**
  - `apply_all_changes` was first-order but had to manually handle scoped outcomes
  - Used `TaggedWriter.listen` which required complex scoped handler
  - ~150 lines of fragile handler code

  **New approach (Hefty algebras):**
  - `apply_all_changes` is higher-order (takes computation parameter)
  - Elaborates to first-order effects using `HeftyTaggedWriter.listen`
  - Algebra is ~20 lines, handler is simple
  - Suspensions/errors handled uniformly by runtime

  ## Scenario

  Process a collection of User records:
  1. Query users from storage
  2. Map over each user, removing email fields
  3. Track each change with HeftyTaggedWriter
  4. Count processed records with State
  5. Use `apply_all_changes` to capture changes and bulk update
  6. Elaborate higher-order ops before interpretation

  This pattern is useful for:
  - Audit logging with bulk commits
  - Batch database updates
  - Change tracking and replay
  - Transactional operations with rollback
  """

  import Freyja.Freer.Sig.DefEffectStruct
  import Freyja.Hefty.Sig.DefHeftyStruct
  import Freyja.HeftyMacro

  alias Freyja.Effects.State
  alias Freyja.Effects.TaggedWriter
  alias Freyja.Hefty.Effects.HeftyFxList
  alias Freyja.Hefty.Effects.HeftyTaggedWriter

  # Storage Effect Definition - Mixed first-order and higher-order
  defmodule Storage do
    @moduledoc """
    Storage effect with both first-order and higher-order operations.

    ## First-order operations (handled by Storage.Handler):
    - `query(ids)` - Retrieve records by IDs
    - `change(old, new)` - Record a change (writes to TaggedWriter)
    - `update_all(changes)` - Apply a list of changes in bulk

    ## Higher-order operations (elaborated by Storage.Algebra):
    - `apply_all_changes(computation)` - Execute computation, capture changes, bulk update

    This demonstrates that a single effect signature can have BOTH kinds of operations.
    The macro system handles this cleanly:
    - `def_effect_struct` creates first-order operation structs
    - `def_hefty_struct` creates higher-order operation structs
    - Both live in the same module namespace
    """

    import Freyja.Freer.Sig.DefEffectStruct
    import Freyja.Hefty.Sig.DefHeftyStruct

    # First-order operations - go directly to Freer
    def_effect_struct(Query, ids: [])
    def_effect_struct(Change, old: nil, new: nil)
    def_effect_struct(UpdateAll, changes: [])

    # Higher-order operation - must be elaborated first
    def_hefty_struct(ApplyAllChanges, [])

    @doc "Query records by IDs (first-order)"
    def query(ids), do: %Query{ids: ids}

    @doc """
    Record a change from old record to new record (first-order).
    Writes the change to the :changes tag in TaggedWriter.
    """
    def change(old, new), do: %Change{old: old, new: new}

    @doc """
    Apply a list of changes in a single bulk operation (first-order).
    Returns the number of records updated.
    """
    def update_all(changes), do: %UpdateAll{changes: changes}

    @doc """
    Execute computation with change capture and bulk update (higher-order).

    This is the key higher-order operation that:
    1. Runs the computation (which calls `change` operations)
    2. Captures all changes via HeftyTaggedWriter.listen
    3. Applies changes in bulk via `update_all`
    4. Returns {result, all_logs}

    Elaborated by Storage.Algebra into first-order operations.
    """
    def apply_all_changes(computation) do
      Freyja.Hefty.send_hefty(
        __MODULE__,
        %ApplyAllChanges{},
        %{inner: computation}
      )
    end
  end

  # Storage Handler - handles ONLY first-order operations
  defmodule Storage.Handler do
    @moduledoc """
    Handler for first-order Storage operations.

    This handler is simple because it only handles first-order ops:
    - Query, Change, UpdateAll

    The higher-order `apply_all_changes` is elaborated by Storage.Algebra
    before reaching this handler, so we never see it here.

    Handler state is a map of user_id => user_record.
    """

    alias Freyja.Freer.Impure
    alias Freyja.Examples.HeftyChangeCapture.Storage
    alias Freyja.Examples.HeftyChangeCapture.Storage.Query
    alias Freyja.Examples.HeftyChangeCapture.Storage.Change
    alias Freyja.Examples.HeftyChangeCapture.Storage.UpdateAll
    alias Freyja.Effects.TaggedWriter
    alias Freyja.Run.RunState

    @behaviour Freyja.EffectHandler

    @impl Freyja.EffectHandler
    def handles?(%Impure{sig: sig}, _state) do
      sig == Storage
    end

    @impl Freyja.EffectHandler
    def interpret(
          %Impure{sig: Storage, data: operation, q: q},
          _handler_key,
          state,
          %RunState{} = _run_state
        ) do
      alias Freyja.Freer

      case operation do
        %Query{ids: ids} ->
          # Query records by IDs
          records = Enum.map(ids, fn id -> Map.get(state, id) end) |> Enum.filter(&(&1 != nil))
          {Freer.Impl.q_apply(q, records), state}

        %Change{old: old, new: new} ->
          # Record a change by writing to TaggedWriter
          # This doesn't modify storage state yet - just logs the change
          tell_computation = TaggedWriter.tell(:changes, {old, new})
          {Freer.Impl.bindp(tell_computation, q), state}

        %UpdateAll{changes: changes} ->
          # Apply all changes in bulk
          updated_state =
            Enum.reduce(changes, state, fn {old, new}, acc ->
              if old.id do
                Map.put(acc, old.id, new)
              else
                acc
              end
            end)

          # Return count of changes applied
          {Freer.Impl.q_apply(q, length(changes)), updated_state}
      end
    end
  end

  # Storage Algebra - elaborates ONLY higher-order operations
  defmodule Storage.Algebra do
    @moduledoc """
    Algebra for elaborating Storage higher-order operations.

    This algebra handles ONLY `apply_all_changes` - the first-order
    operations are not seen here, they go directly to the handler.

    ## The Power of Hefty Algebras

    Compare this ~25 line algebra to the ~150 line scoped handler in old ChangeCapture!

    The elaboration is simple:
    1. Use HeftyTaggedWriter.listen to wrap the inner computation
    2. Extract captured changes from logs
    3. Call update_all to apply changes in bulk
    4. Return {result, all_logs}

    No manual outcome handling, no suspension special cases, no queue management.
    """

    @behaviour Freyja.Hefty.Algebra

    alias Freyja.Examples.HeftyChangeCapture.Storage
    alias Freyja.Examples.HeftyChangeCapture.Storage.ApplyAllChanges
    alias Freyja.Hefty.Effects.HeftyTaggedWriter
    alias Freyja.Freer
    import Freyja.Con

    @impl true
    def handles?(sig) when sig == Storage, do: true
    def handles?(_), do: false

    @impl true
    def elaborate(%ApplyAllChanges{}, psi, k, _elaborator) do
      # Extract already-elaborated inner computation (now Freer)
      inner_comp = Map.fetch!(psi, :inner)

      # Elaborate to: use RunListen to capture changes, update_all to apply them
      # This is the entire higher-order operation elaboration!
      con do
        # Use RunListen runner effect (first-order, already defined)
        {result, all_logs} <- HeftyTaggedWriter.RunListen.run_listen(inner_comp)

        # Extract captured changes
        changes = all_logs[:changes] || []

        # Apply changes in bulk (first-order operation)
        _update_count <- Storage.update_all(changes)

        # Continue with result and logs
        k.({result, all_logs})
      end
    end
  end

  # Example: Remove email from users with change tracking
  defhefty remove_email_from_user(user) do
    # Create new user without email
    updated_user = Map.delete(user, :email)

    # Record the change (first-order, lifted automatically)
    Storage.change(user, updated_user)

    # Increment processed count (first-order, lifted automatically)
    State.update(&(&1 + 1))

    return(updated_user)
  end

  defhefty process_users(user_ids) do
    # Query users from storage (first-order, lifted)
    users <- Storage.query(user_ids)

    # Process users with change tracking
    # apply_all_changes is higher-order - uses HeftyFxList and HeftyTaggedWriter
    {updated_users, all_logs} <-
      Storage.apply_all_changes(HeftyFxList.fx_map(users, &remove_email_from_user/1))

    captured_changes = all_logs[:changes] || []

    # Get final count of processed records (lifted)
    processed_count <- State.get()

    return(%{
      updated_users: updated_users,
      captured_changes: captured_changes,
      processed_count: processed_count,
      update_count: Enum.count(captured_changes)
    })
  end

  # More complex example: Conditional updates with validation
  defhefty validate_and_update_user(user) do
    # Only remove email if it's a test email
    is_test_email = String.ends_with?(user.email || "", "@test.com")

    updated_user <-
      if is_test_email do
        hefty do
          new_user = Map.put(user, :email, nil)
          Storage.change(user, new_user)
          TaggedWriter.tell(:validations, {:removed_test_email, user.id})
          return(new_user)
        end
      else
        hefty do
          TaggedWriter.tell(:validations, {:kept_email, user.id})
          return(user)
        end
      end

    # Increment processed count
    State.update(&(&1 + 1))

    return(updated_user)
  end

  defhefty process_users_with_validation(user_ids) do
    # Query users (lifted)
    users <- Storage.query(user_ids)

    # Process with both change and validation tracking
    {updated_users, all_logs} <-
      Storage.apply_all_changes(HeftyFxList.fx_map(users, &validate_and_update_user/1))

    # Extract the specific logs we care about
    captured_changes = all_logs[:changes] || []
    validation_results = all_logs[:validations] || []

    # Get processed count (lifted)
    processed_count <- State.get()

    return(%{
      updated_users: updated_users,
      changes_applied: Enum.count(captured_changes),
      processed_count: processed_count,
      validations: validation_results
    })
  end

  # Example: Multi-stage processing with multiple listen scopes
  defhefty anonymize_user(user) do
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

  defhefty audit_user(user) do
    # Log audit trail
    TaggedWriter.tell(:audit, %{
      action: :reviewed,
      user_id: user.id,
      timestamp: System.system_time()
    })

    State.update(&(&1 + 1))

    return(user)
  end

  defhefty multi_stage_process(user_ids) do
    users <- Storage.query(user_ids)

    # Stage 1: Anonymization with change capture
    {anonymized_users, stage1_logs} <-
      Storage.apply_all_changes(HeftyFxList.fx_map(users, &anonymize_user/1))

    anonymize_changes = stage1_logs[:changes] || []
    TaggedWriter.tell(:stages, {:anonymization_complete, length(anonymize_changes)})

    # Stage 2: Audit trail
    {_audited_users, stage2_logs} <-
      HeftyTaggedWriter.listen(HeftyFxList.fx_map(anonymized_users, &audit_user/1))

    audit_logs = stage2_logs[:audit] || []
    TaggedWriter.tell(:stages, {:audit_complete, length(audit_logs)})

    # Get final counts (both lifted)
    total_processed <- State.get()
    all_stages <- TaggedWriter.peek(:stages)

    return(%{
      anonymized: length(anonymize_changes),
      audited: length(audit_logs),
      total_processed: total_processed,
      stages: all_stages
    })
  end
end
