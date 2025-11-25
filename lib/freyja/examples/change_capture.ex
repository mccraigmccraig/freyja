defmodule Freyja.Examples.ChangeCapture do
  @moduledoc """
  Example demonstrating real-world effectful processing using effect composition.

  This showcases the key benefit of algebraic effects: **Effect Polymorphism**

  The `process_users/2` function takes a `process_user_fn` parameter and doesn't
  need to know what effects it uses:

      # Simple email removal - uses Changes.change + State
      process_users(ids, &remove_email_from_user/1)

      # With validation - adds TaggedWriter effect
      process_users(ids, &validate_and_update_user/1)

      # Audit only - uses TaggedWriter + State, NO Changes.change
      process_users(ids, &audit_user/1)

  **No parameter threading!** No accumulators, no context objects, no callbacks.
  The processing function uses whatever effects it needs, and they compose naturally.

  Compare to traditional approaches:
  - Callbacks: Must wire up each callback manually
  - Context objects: Must thread context through every function
  - Accumulators: Must add parameters for each type of output
  - Reader/Writer monads: Must stack transformers and lift everywhere

  With algebraic effects: **Just write the code. Effects compose automatically.**

  ## Composing Existing Effects

  This example demonstrates composing existing effects rather than creating
  redundant wrappers:

  - `Changes.change/2` - Records a change (from `Freyja.Effects.Changes`)
  - `Changes.capture/1` - Captures all changes in a scope (higher-order)
  - `Storage.update_all/1` - Applies changes in bulk (domain-specific)

  The Storage effect is minimal - just `update_all` for bulk application.
  All change tracking uses the general-purpose Changes effect.

  ## Scenario

  Process a collection of User records with pluggable processing logic:
  1. Query users from storage
  2. Map over each user with supplied processing function
  3. Capture changes via `Changes.capture/1`
  4. Apply changes in bulk via `Storage.update_all/1`
  5. Return results

  This pattern is useful for:
  - Audit logging with bulk commits
  - Batch database updates with flexible processing
  - Change tracking and replay
  - Effect-polymorphic pipelines
  """

  import Freyja.Freer.Sig.DefEffectStruct

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

  alias Freyja.Effects.{State, TaggedWriter, FxList, Lift, Query, Changes}
  alias __MODULE__.UserQuery

  # Storage Effect Definition - simple first-order only
  defmodule Storage do
    @moduledoc """
    Storage effect for bulk update operations.

    This is a simple first-order effect with just one operation:
    - `update_all(changes)` - Apply a list of changes in bulk

    Change capture is handled by the general-purpose `Freyja.Effects.Changes` effect,
    which provides `Changes.change/2` for recording changes and `Changes.capture/1`
    for scoped capture. This example demonstrates how to compose these existing
    effects rather than creating redundant wrappers.
    """

    def_effect_struct(UpdateAll, changes: [])
    alias Freyja.Freer

    @doc """
    Apply a list of changes in a single bulk operation.
    Returns the number of records updated.
    """
    def update_all(changes), do: %UpdateAll{changes: changes} |> Freer.send_effect()
  end

  # Storage Handler - handles UpdateAll operation
  defmodule Storage.Handler do
    @moduledoc """
    Handler for Storage.UpdateAll operation.

    Handler state is a map of user_id => user_record.
    """

    alias Freyja.Freer.Impure
    alias Freyja.Examples.ChangeCapture.Storage
    alias Freyja.Examples.ChangeCapture.Storage.UpdateAll
    alias Freyja.Run.RunState

    @behaviour Freyja.Freer.EffectHandler

    @impl Freyja.Freer.EffectHandler
    def handles?(%Impure{sig: sig}, _state) do
      sig == Storage
    end

    @impl Freyja.Freer.EffectHandler
    def interpret(
          %Impure{sig: Storage, data: %UpdateAll{changes: changes}, q: q},
          _handler_key,
          state,
          %RunState{} = _run_state
        ) do
      alias Freyja.Freer

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

    @doc "Add Storage.Handler to the run pipeline with initial state"
    def run(computation_or_builder, initial_state) do
      Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
    end
  end

  @doc """
  Generic user processing with change capture.

  This is the KEY example showing effect polymorphism and composition!

  The `process_user_fn` can use ANY effects it wants:
  - State (for counting)
  - TaggedWriter (for logging/validation)
  - Changes.change (for recording changes)
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

    # Process users with change tracking using Changes.capture directly
    #
    # The process_user_fn can use ANY effects - we don't need to know!
    #
    # Changes.capture/1 scopes the computation so every Changes.change/2 call
    # is captured. After the entire batch is processed, we apply the
    # aggregated changes in one go with Storage.update_all/1.
    #
    # You write simple single-value oriented pure functions, but get
    # bulk-operation performance
    {updated_users, captured_changes} <-
      Changes.capture(FxList.fx_map(users, process_user_fn))

    # Apply all captured changes in bulk
    _update_count <- Storage.update_all(captured_changes)

    # Get final count of processed records (auto-lifted)
    processed_count <- State.get()

    return(%{
      updated_users: updated_users,
      changes: captured_changes,
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
    |> Changes.Algebra.run()
    |> FxList.Algebra.run()
    |> TaggedWriter.Algebra.run()
    |> Storage.Handler.run(users)
    |> TaggedWriter.Handler.run(%{})
    |> Changes.Handler.run()
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
    |> Changes.Algebra.run()
    |> FxList.Algebra.run()
    |> TaggedWriter.Algebra.run()
    |> Storage.Handler.run(users)
    |> TaggedWriter.Handler.run(%{})
    |> Changes.Handler.run()
    |> State.Handler.run(initial_count)
  end

  # Example processing functions - each uses different effects

  @doc """
  Simple email removal - uses Changes.change and State effects.
  """
  defhefty remove_email_from_user(user) do
    updated_user = Map.delete(user, :email)

    # Record the change
    _ <- Changes.change(user, updated_user)

    # Increment processed count
    _ <- State.update(&(&1 + 1))

    return(updated_user)
  end

  @doc """
  Conditional updates with validation - uses Changes.change, State, and TaggedWriter.

  Notice: the processing function uses MORE effects than remove_email_from_user,
  but process_users doesn't need to change! Effect polymorphism!
  """
  defhefty validate_and_update_user(user) do
    is_test_email = String.ends_with?(user.email || "", "@test.com")

    updated_user <-
      if is_test_email do
        hefty do
          new_user = Map.put(user, :email, nil)
          _ <- Changes.change(user, new_user)
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

    _ <- Changes.change(user, anonymized)
    _ <- State.update(&(&1 + 1))

    return(anonymized)
  end

  @doc """
  Audit logging - different effects than the others!
  Uses TaggedWriter and State, but NOT Changes.change.

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
    anonymize_changes = stage1_result.changes

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
