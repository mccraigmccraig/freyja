defmodule Freyja.Examples.ChangeCapture do
  @moduledoc """
  Example demonstrating real-world effectful processing using Hefty algebras.

  This showcases TWO key benefits of algebraic effects with Hefty:

  ## 1. Effect Polymorphism (The Main Point!)

  The `process_users/2` function takes a `process_user_fn` parameter and doesn't
  need to know what effects it uses:

      # Simple email removal - uses Storage.change + State
      process_users(ids, &remove_email_from_user/1)

      # With validation - adds TaggedWriter effect
      process_users(ids, &validate_and_update_user/1)

      # Audit only - uses TaggedWriter + State, NO Storage.change
      process_users(ids, &audit_user/1)

  **No parameter threading!** No accumulators, no context objects, no callbacks.
  The processing function uses whatever effects it needs, and they compose naturally.

  Compare to traditional approaches:
  - Callbacks: Must wire up each callback manually
  - Context objects: Must thread context through every function
  - Accumulators: Must add parameters for each type of output
  - Reader/Writer monads: Must stack transformers and lift everywhere

  With algebraic effects: **Just write the code. Effects compose automatically.**

  ## 2. Complexity Reduction via Hefty Algebras

  **Old approach (Freer scoped effects):**
  - ~150 lines of complex scoped handler code
  - Manual RunOutcome handling
  - Fragile suspension management
  - Hard to understand and maintain

  **New approach (Hefty algebras):**
  - ~25 lines of simple algebra code
  - No manual outcome handling
  - Suspensions handled uniformly
  - Self-explanatory

  ## Mixed First-Order and Higher-Order Effects

  The Storage effect demonstrates that a SINGLE signature can have BOTH:
  - First-order: `query`, `change`, `update_all` (handled by EffectHandler)
  - Higher-order: `apply_all_changes` (elaborated by Algebra)

  Both `def_effect_struct` and `def_hefty_struct` coexist in the same module.

  ## Scenario

  Process a collection of User records with pluggable processing logic:
  1. Query users from storage
  2. Map over each user with supplied processing function
  3. Capture changes via HeftyTaggedWriter
  4. Apply changes in bulk
  5. Return results with captured logs

  This pattern is useful for:
  - Audit logging with bulk commits
  - Batch database updates with flexible processing
  - Change tracking and replay
  - Effect-polymorphic pipelines
  """

  import Freyja.Freer.Sig.DefEffectStruct
  import Freyja.Hefty.Sig.DefHeftyStruct

  defmodule UserQuery do
    @moduledoc false

    def fetch_users(_params), do: :handled_by_registry

    def resolver(users) do
      fn
        :users, _mod, _name, %{ids: ids} ->
          ids
          |> Enum.map(&Map.get(users, &1))
          |> Enum.filter(& &1)

        domain, mod, name, params ->
          raise ArgumentError,
                "Unsupported query #{inspect({domain, mod, name, params})} in ChangeCapture"
      end
    end
  end

  use Freyja.Syntax

  alias Freyja.Effects.{State, TaggedWriter, FxList, Lift, Query}
  alias __MODULE__.UserQuery

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

    # First-order operations - go directly to Freer
    def_effect_struct(Change, old: nil, new: nil)
    def_effect_struct(UpdateAll, changes: [])
    alias Freyja.Freer

    # Higher-order operation - must be elaborated first
    def_hefty_struct(ApplyAllChanges, [])

    @doc """
    Record a change from old record to new record (first-order).
    Writes the change to the :changes tag in TaggedWriter.
    """
    def change(old, new), do: %Change{old: old, new: new} |> Freer.send_effect()

    @doc """
    Apply a list of changes in a single bulk operation (first-order).
    Returns the number of records updated.
    """
    def update_all(changes), do: %UpdateAll{changes: changes} |> Freer.send_effect()

    @doc """
    Execute computation with change capture and bulk update (higher-order).

    This is the key higher-order operation that:
    1. Runs the computation (which calls `change` operations)
    2. Captures all changes via TaggedWriter.listen
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
    alias Freyja.Examples.ChangeCapture.Storage
    alias Freyja.Examples.ChangeCapture.Storage.Change
    alias Freyja.Examples.ChangeCapture.Storage.UpdateAll
    alias Freyja.Effects.TaggedWriter
    alias Freyja.Run.RunState

    @behaviour Freyja.Freer.EffectHandler

    @impl Freyja.Freer.EffectHandler
    def handles?(%Impure{sig: sig}, _state) do
      sig == Storage
    end

    @impl Freyja.Freer.EffectHandler
    def interpret(
          %Impure{sig: Storage, data: operation, q: q},
          _handler_key,
          state,
          %RunState{} = _run_state
        ) do
      alias Freyja.Freer

      case operation do
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

    @doc "Add Storage.Handler to the run pipeline with initial state"
    def run(computation_or_builder, initial_state) do
      Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
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
    1. Use TaggedWriter.listen to wrap the inner computation
    2. Extract captured changes from logs
    3. Call update_all to apply changes in bulk
    4. Return {result, all_logs}

    No manual outcome handling, no suspension special cases, no queue management.
    """

    @behaviour Freyja.Hefty.Algebra

    alias Freyja.Examples.ChangeCapture.Storage
    alias Freyja.Examples.ChangeCapture.Storage.ApplyAllChanges
    alias Freyja.Effects.TaggedWriter
    alias Freyja.Freer

    use Freyja.Syntax

    @impl true
    def handles?(sig) when sig == Storage, do: true
    def handles?(_), do: false

    @impl true
    def elaborate(%ApplyAllChanges{}, psi, k, _elaborator) do
      # Extract already-elaborated inner computation (now Freer)
      inner_comp = Map.fetch!(psi, :inner)

      # Elaborate to: use PeekAll to capture changes, update_all to apply them
      # This is the entire higher-order operation elaboration!
      con do
        # Get initial logs
        initial_logs <- TaggedWriter.peek_all()

        # Run the inner computation
        result <- inner_comp

        # Get final logs
        final_logs <- TaggedWriter.peek_all()

        # Calculate captured logs
        all_logs = calculate_captured_logs(initial_logs, final_logs)

        # Extract captured changes
        changes = all_logs[:changes] || []

        # Apply changes in bulk (first-order operation)
        _update_count <- Storage.update_all(changes)

        # Continue with result and logs
        k.({result, all_logs})
      end
    end

    # Calculate what logs were added by comparing initial and final states
    defp calculate_captured_logs(initial, final) do
      final
      |> Enum.map(fn {tag, final_tag_log} ->
        initial_tag_log = Map.get(initial, tag, [])
        # New logs are at the front (prepended)
        new_logs = Enum.take(final_tag_log, length(final_tag_log) - length(initial_tag_log))
        {tag, new_logs}
      end)
      |> Enum.into(%{})
    end

    @doc "Add Storage.Algebra to the run pipeline"
    def run(computation_or_builder) do
      Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__)
    end
  end

  @doc """
  Generic user processing with change capture.

  This is the KEY example showing effect polymorphism and composition!

  The `process_user_fn` can use ANY effects it wants:
  - State (for counting)
  - TaggedWriter (for logging/validation)
  - Storage.change (for recording changes)
  - Error (for throwing)
  - Any combination!

  The caller doesn't need to know what effects are used. No need to:
  - Thread state parameters through
  - Pass accumulators for logging
  - Manually wire up callbacks
  - Add parameters for every possible output

  The effects compose naturally. This is the power of algebraic effects!
  """
  defhefty process_users(user_ids, process_user_fn) do
    # Query users via Query effect (backend-agnostic)
    users <- Query.request(:users, UserQuery, :fetch_users, %{ids: user_ids})

    # Process users with change tracking
    #
    # The process_user_fn can use ANY effects - we don't need to know!
    #
    # Storage.apply_all_changes is a "higher-order" operation - it
    # takes a computation as a parameter, and captures the outputs
    # it needs by running that computation
    #
    # In this case, it captures all the values given to any
    # Storage.change operations in the process_user_fn calls
    #
    # All Storage.change does is append the change to a list (internally
    # using a TaggedWriter.tell effect) - so the process_user_fn doesn't
    # need to write to the db - it is effectively pure
    #
    # Storage.apply_all_changes internally uses a TaggedWriter.listen
    # effect to retrieve all the logged changes after all the calls
    # to process_user_fn have been made, and it can then apply all the
    # changes to the (hypothetical) database in a single bulk operation
    #
    # You write simple single-value oriented pure functions, but get
    # bulk-operation performance
    {updated_users, all_logs} <-
      Storage.apply_all_changes(FxList.fx_map(users, process_user_fn))

    # Get final count of processed records (auto-lifted)
    processed_count <- State.get()

    return(%{
      updated_users: updated_users,
      all_logs: all_logs,
      processed_count: processed_count
    })
  end

  @doc """
  Build a runnable pipeline for this example so it can be executed from IEx.

      alias Freyja.Examples.ChangeCapture

      builder =
        ChangeCapture.builder(
          [1, 2],
          &ChangeCapture.remove_email_from_user/1,
          users: %{
            1 => %{id: 1, email: "a@test.com", name: "Alice"},
            2 => %{id: 2, email: "b@test.com", name: "Bob"}
          },
          initial_count: 0
        )

      outcome = Freyja.Run.run(builder)
      outcome.result
      outcome.outputs[Freyja.Examples.ChangeCapture.Storage.Handler]
  """
  def builder(user_ids, process_fun \\ &remove_email_from_user/1, opts \\ []) do
    users = Keyword.get(opts, :users, %{})
    initial_count = Keyword.get(opts, :initial_count, 0)
    query_registry = %{users: UserQuery.resolver(users)}

    process_users(user_ids, process_fun)
    |> Query.Handler.run(query_registry)
    |> Lift.Algebra.run()
    |> Storage.Algebra.run()
    |> FxList.Algebra.run()
    |> TaggedWriter.Algebra.run()
    |> Storage.Handler.run(users)
    |> TaggedWriter.Handler.run(%{})
    |> State.Handler.run(initial_count)
  end

  @doc """
  Build a pipeline for `multi_stage_process/1` with the same storage/query setup.
  """
  def multi_stage_builder(user_ids, opts \\ []) do
    users = Keyword.get(opts, :users, %{})
    initial_count = Keyword.get(opts, :initial_count, 0)
    query_registry = %{users: UserQuery.resolver(users)}

    multi_stage_process(user_ids)
    |> Query.Handler.run(query_registry)
    |> Lift.Algebra.run()
    |> Storage.Algebra.run()
    |> FxList.Algebra.run()
    |> TaggedWriter.Algebra.run()
    |> Storage.Handler.run(users)
    |> TaggedWriter.Handler.run(%{})
    |> State.Handler.run(initial_count)
  end

  # Example processing functions - each uses different effects

  @doc """
  Simple email removal - uses Storage.change and State effects.
  """
  defhefty remove_email_from_user(user) do
    updated_user = Map.delete(user, :email)

    # Record the change
    _ <- Storage.change(user, updated_user)

    # Increment processed count
    _ <- State.update(&(&1 + 1))

    return(updated_user)
  end

  @doc """
  Conditional updates with validation - uses Storage.change, State, and TaggedWriter.

  Notice: the processing function uses MORE effects than remove_email_from_user,
  but process_users doesn't need to change! Effect polymorphism!
  """
  defhefty validate_and_update_user(user) do
    is_test_email = String.ends_with?(user.email || "", "@test.com")

    updated_user <-
      if is_test_email do
        hefty do
          new_user = Map.put(user, :email, nil)
          _ <- Storage.change(user, new_user)
          # Extra effect: validation logging
          _ <- TaggedWriter.tell(:validations, {:removed_test_email, user.id})
          return(new_user)
        end
      else
        hefty do
          # Extra effect: validation logging (different tag)
          _ <- TaggedWriter.tell(:validations, {:kept_email, user.id})
          return(user)
        end
      end

    _ <- State.update(&(&1 + 1))
    return(updated_user)
  end

  @doc """
  Anonymization - removes PII fields.
  Uses same effects as remove_email_from_user but different logic.
  """
  defhefty anonymize_user(user) do
    anonymized = %{
      id: user.id,
      created_at: user.created_at
      # email, name removed
    }

    _ <- Storage.change(user, anonymized)
    _ <- State.update(&(&1 + 1))

    return(anonymized)
  end

  @doc """
  Audit logging - different effects than the others!
  Uses TaggedWriter and State, but NOT Storage.change.

  This shows you can pass ANY effectful function to process_users.
  """
  defhefty audit_user(user) do
    _ <-
      TaggedWriter.tell(:audit, %{
        action: :reviewed,
        user_id: user.id,
        timestamp: System.system_time()
      })

    _ <- State.update(&(&1 + 1))

    return(user)
  end

  @doc """
  Multi-stage processing demonstrating composition of process_users.

  Notice: We call process_users twice with different processing functions,
  then compose the results. No need to create separate process_users_* variants!
  """
  defhefty multi_stage_process(user_ids) do
    # Stage 1: Anonymization with change capture
    stage1_result <- process_users(user_ids, &anonymize_user/1)
    anonymized_users = stage1_result.updated_users
    anonymize_changes = stage1_result.all_logs[:changes] || []

    _ <- TaggedWriter.tell(:stages, {:anonymization_complete, length(anonymize_changes)})

    # Stage 2: Audit trail (on already-processed users)
    # Notice: We use TaggedWriter.listen directly here to get fresh user list
    {_audited_users, audit_logs} <-
      TaggedWriter.listen(FxList.fx_map(anonymized_users, &audit_user/1))

    audit_entries = audit_logs[:audit] || []
    _ <- TaggedWriter.tell(:stages, {:audit_complete, length(audit_entries)})

    # Get final counts
    total_processed <- State.get()
    all_stages <- TaggedWriter.peek(:stages)

    return(%{
      anonymized: length(anonymize_changes),
      audited: length(audit_entries),
      total_processed: total_processed,
      stages: all_stages
    })
  end
end
