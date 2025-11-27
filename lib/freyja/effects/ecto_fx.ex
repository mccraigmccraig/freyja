if Code.ensure_loaded?(Ecto) do
  defmodule Freyja.Effects.EctoFx do
    @moduledoc """
    Unified Ecto effect combining Query, Mutate, Changes, and Transaction.

    This effect provides a complete interface for Ecto database operations,
    including queries, mutations, change capture, and transactions. All operations
    share connection state, enabling proper transaction support.

    ## First-Order Operations

    ### Queries

        result <- EctoFx.query(MyQueries, :find_user, %{id: 1})

    ### Single Mutations

        user <- EctoFx.insert(user_changeset)
        user <- EctoFx.update(user_changeset)
        user <- EctoFx.delete(user)
        user <- EctoFx.insert_or_update(user_changeset)

    ### Bulk Mutations

        {count, _} <- EctoFx.insert_all(User, entries, on_conflict: :replace_all)
        {count, _} <- EctoFx.update_all(User, [set: [active: false]])
        {count, _} <- EctoFx.delete_all(from u in User, where: u.inactive)

    ### Change Recording (for capture)

        _ <- EctoFx.change(:insert, changeset)
        _ <- EctoFx.change(:update, changeset)
        _ <- EctoFx.change(:delete, changeset)

    ## Higher-Order Operations

    ### Transactions

        result <- EctoFx.transaction(
          hefty do
            user <- EctoFx.insert(user_changeset)
            order <- EctoFx.insert(order_changeset)
            return({user, order})
          end
        )

    ### Change Capture

        {result, changes} <- EctoFx.capture(
          hefty do
            _ <- EctoFx.change(:insert, user_changeset)
            _ <- EctoFx.change(:update, order_changeset)
            return(:ok)
          end
        )
        # changes = %{inserts: [...], updates: [...], deletes: [...]}

    ## Handler Setup

        computation
        |> EctoFx.run(MyApp.Repo, query_registry)
        |> Run.run()

    ## Example: Full Workflow

        defhefty process_users(users) do
          result <- EctoFx.transaction(
            hefty do
              {processed, changes} <- EctoFx.capture(
                FxList.fx_map(users, &process_user/1)
              )

              # Apply all captured inserts in bulk
              _ <- EctoFx.insert_all(User, EctoFx.to_entries(changes.inserts),
                     on_conflict: :replace_all)

              # Apply updates individually
              _ <- FxList.fx_map(changes.updates, &EctoFx.update/1)

              return(processed)
            end
          )
          return(result)
        end

        defhefty process_user(user) do
          changeset = User.changeset(user, %{processed_at: DateTime.utc_now()})
          _ <- EctoFx.change(:update, changeset)
          return(user)
        end
    """

    import Freyja.Freer.Sig.DefEffectStruct
    import Freyja.Hefty.Sig.DefHeftyStruct

    alias Freyja.Freer

    # ============================================================================
    # Effect Structs
    # ============================================================================

    # Query
    def_effect_struct(Query, mod: nil, name: nil, params: %{})

    # Single mutations
    def_effect_struct(Insert, changeset: nil, opts: [])
    def_effect_struct(Update, changeset: nil, opts: [])
    def_effect_struct(Delete, struct_or_changeset: nil, opts: [])
    def_effect_struct(InsertOrUpdate, changeset: nil, opts: [])

    # Bulk mutations
    def_effect_struct(InsertAll, schema: nil, entries: [], opts: [])
    def_effect_struct(UpdateAll, queryable: nil, updates: [], opts: [])
    def_effect_struct(DeleteAll, queryable: nil, opts: [])

    # Change recording
    def_effect_struct(Change, op: nil, changeset: nil)

    # Higher-order operations
    def_hefty_struct(Transaction, opts: [])
    def_hefty_struct(Capture, [])

    # ============================================================================
    # Types
    # ============================================================================

    @typedoc "Ecto changeset"
    @type changeset :: Ecto.Changeset.t()

    @typedoc "Ecto schema module"
    @type schema :: module()

    @typedoc "Ecto queryable (schema, query, or table name)"
    @type queryable :: Ecto.Queryable.t()

    @typedoc "Repo operation options"
    @type opts :: keyword()

    @typedoc "Query module implementing query functions"
    @type query_module :: module()

    @typedoc "Function exported by query module"
    @type query_name :: atom()

    @typedoc "Query parameters"
    @type params :: map() | struct()

    @typedoc "Change operation type"
    @type change_op :: :insert | :update | :delete

    @typedoc "Captured changes grouped by operation type"
    @type captured_changes :: %{
            inserts: [changeset()],
            updates: [changeset()],
            deletes: [changeset()]
          }

    # ============================================================================
    # Public API - Queries
    # ============================================================================

    @doc """
    Execute a query through the configured registry.

    The query is dispatched based on the module, which should be registered
    in the handler's query registry.

    ## Example

        users <- EctoFx.query(MyQueries, :find_active_users, %{limit: 10})
    """
    @spec query(query_module(), query_name(), params()) :: Freer.t()
    def query(mod, name, params \\ %{}) do
      %Query{mod: mod, name: name, params: params}
      |> Freer.send_effect()
    end

    # ============================================================================
    # Public API - Single Mutations
    # ============================================================================

    @doc """
    Insert a new record from a changeset.

    Returns the inserted struct on success, or raises via Throw effect on error.
    """
    @spec insert(changeset(), opts()) :: Freer.t()
    def insert(changeset, opts \\ []) do
      %Insert{changeset: changeset, opts: opts}
      |> Freer.send_effect()
    end

    @doc """
    Update an existing record from a changeset.

    Returns the updated struct on success, or raises via Throw effect on error.
    """
    @spec update(changeset(), opts()) :: Freer.t()
    def update(changeset, opts \\ []) do
      %Update{changeset: changeset, opts: opts}
      |> Freer.send_effect()
    end

    @doc """
    Delete a record.

    Accepts either a struct or a changeset. Returns the deleted struct on success.
    """
    @spec delete(struct() | changeset(), opts()) :: Freer.t()
    def delete(struct_or_changeset, opts \\ []) do
      %Delete{struct_or_changeset: struct_or_changeset, opts: opts}
      |> Freer.send_effect()
    end

    @doc """
    Insert or update a record based on whether it has a primary key.

    Returns the inserted/updated struct on success.
    """
    @spec insert_or_update(changeset(), opts()) :: Freer.t()
    def insert_or_update(changeset, opts \\ []) do
      %InsertOrUpdate{changeset: changeset, opts: opts}
      |> Freer.send_effect()
    end

    # ============================================================================
    # Public API - Bulk Mutations
    # ============================================================================

    @doc """
    Insert multiple records at once.

    Returns `{count, nil | [struct]}` where count is the number of inserted records.
    The second element depends on the `:returning` option.
    """
    @spec insert_all(schema(), [map() | keyword()], opts()) :: Freer.t()
    def insert_all(schema, entries, opts \\ []) do
      %InsertAll{schema: schema, entries: entries, opts: opts}
      |> Freer.send_effect()
    end

    @doc """
    Update multiple records matching a query.

    Returns `{count, nil | [struct]}` where count is the number of updated records.
    """
    @spec update_all(queryable(), keyword(), opts()) :: Freer.t()
    def update_all(queryable, updates, opts \\ []) do
      %UpdateAll{queryable: queryable, updates: updates, opts: opts}
      |> Freer.send_effect()
    end

    @doc """
    Delete multiple records matching a query.

    Returns `{count, nil | [struct]}` where count is the number of deleted records.
    """
    @spec delete_all(queryable(), opts()) :: Freer.t()
    def delete_all(queryable, opts \\ []) do
      %DeleteAll{queryable: queryable, opts: opts}
      |> Freer.send_effect()
    end

    # ============================================================================
    # Public API - Change Recording
    # ============================================================================

    @doc """
    Record a change operation for later capture.

    Used inside `capture/1` to record intended changes without immediately
    applying them. Changes are accumulated and returned when the capture
    scope completes.

    Prefer using `EctoFx.Changes.insert/1`, `EctoFx.Changes.update/1`, or
    `EctoFx.Changes.delete/1` for clearer intent.

    ## Example

        {result, changes} <- EctoFx.capture(
          hefty do
            _ <- EctoFx.Changes.insert(user_changeset)
            _ <- EctoFx.Changes.update(order_changeset)
            return(:ok)
          end
        )
    """
    @spec change(change_op(), changeset()) :: Freer.t()
    def change(op, changeset) when op in [:insert, :update, :delete] do
      %Change{op: op, changeset: changeset}
      |> Freer.send_effect()
    end

    # ============================================================================
    # Changes Submodule
    # ============================================================================

    defmodule Changes do
      @moduledoc """
      Convenience functions for recording change operations.

      These functions are used inside `EctoFx.capture/1` to record intended
      changes without immediately persisting them. Changes are accumulated
      and returned when the capture scope completes.

      ## Example

          {result, changes} <- EctoFx.capture(
            hefty do
              _ <- EctoFx.Changes.insert(user_changeset)
              _ <- EctoFx.Changes.update(order_changeset)
              _ <- EctoFx.Changes.delete(old_record_changeset)
              return(:ok)
            end
          )
          # changes = %{inserts: [...], updates: [...], deletes: [...]}
      """

      alias Freyja.Effects.EctoFx.Change
      alias Freyja.Freer

      @doc """
      Record an insert change for later capture.

      ## Example

          _ <- EctoFx.Changes.insert(User.changeset(attrs))
      """
      @spec insert(Ecto.Changeset.t()) :: Freer.t()
      def insert(changeset) do
        %Change{op: :insert, changeset: changeset}
        |> Freer.send_effect()
      end

      @doc """
      Record an update change for later capture.

      ## Example

          _ <- EctoFx.Changes.update(User.activate_changeset(user))
      """
      @spec update(Ecto.Changeset.t()) :: Freer.t()
      def update(changeset) do
        %Change{op: :update, changeset: changeset}
        |> Freer.send_effect()
      end

      @doc """
      Record a delete change for later capture.

      ## Example

          _ <- EctoFx.Changes.delete(Ecto.Changeset.change(user))
      """
      @spec delete(Ecto.Changeset.t()) :: Freer.t()
      def delete(changeset) do
        %Change{op: :delete, changeset: changeset}
        |> Freer.send_effect()
      end
    end

    # ============================================================================
    # Public API - Higher-Order Operations
    # ============================================================================

    @doc """
    Run a computation inside a database transaction.

    If the computation succeeds, the transaction is committed and the result
    is returned. If the computation throws an error, the transaction is
    rolled back and the error is re-thrown.

    ## Options

    All options are passed to `Ecto.Repo.transaction/2`:
    - `:timeout` - Transaction timeout in milliseconds
    - `:isolation_level` - Transaction isolation level

    ## Example

        result <- EctoFx.transaction(
          hefty do
            user <- EctoFx.insert(user_changeset)
            order <- EctoFx.insert(order_changeset)
            return({user, order})
          end
        )
    """
    @spec transaction(Freyja.Hefty.t(), opts()) :: Freyja.Hefty.t()
    def transaction(computation, opts \\ []) do
      Freyja.Hefty.send_hefty(
        __MODULE__,
        %Transaction{opts: opts},
        %{inner: computation}
      )
    end

    @doc """
    Run a computation while capturing change operations.

    Returns `{result, captured_changes}` where `result` is the computation result
    and `captured_changes` is a map with `:inserts`, `:updates`, and `:deletes`
    lists containing the changesets recorded within the scope.

    If the computation throws an error, captured changes are discarded.

    ## Example

        {result, changes} <- EctoFx.capture(
          hefty do
            _ <- EctoFx.change(:insert, user_changeset)
            _ <- EctoFx.change(:update, order_changeset)
            return(:ok)
          end
        )
        # changes = %{inserts: [user_changeset], updates: [order_changeset], deletes: []}
    """
    @spec capture(Freyja.Hefty.t()) :: Freyja.Hefty.t()
    def capture(computation) do
      Freyja.Hefty.send_hefty(
        __MODULE__,
        %Capture{},
        %{inner: computation}
      )
    end

    # ============================================================================
    # Helper Functions (pure, not effects)
    # ============================================================================

    @doc """
    Build a canonical key for query stubbing in tests.

    Parameters are normalized so that structurally-equal maps/structs produce
    the same key, independent of key ordering.
    """
    @spec query_key(query_module(), query_name(), params()) ::
            {query_module(), query_name(), binary()}
    def query_key(mod, name, params) do
      {mod, name, normalize_params(params)}
    end

    @doc false
    @spec normalize_params(term) :: binary()
    def normalize_params(params) do
      params
      |> canonical_term()
      |> :erlang.term_to_binary()
    end

    defp canonical_term(%_{} = struct) do
      struct
      |> Map.from_struct()
      |> Map.put(:__struct__, struct.__struct__)
      |> canonical_term()
    end

    defp canonical_term(map) when is_map(map) do
      map
      |> Enum.map(fn {k, v} -> {k, canonical_term(v)} end)
      |> Enum.sort_by(&elem(&1, 0))
    end

    defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)

    defp canonical_term(tuple) when is_tuple(tuple) do
      {:__tuple__, tuple |> Tuple.to_list() |> Enum.map(&canonical_term/1)}
    end

    defp canonical_term(other), do: other

    @doc """
    Convert a list of changesets to entry maps for use with `insert_all/3`.

    Applies the changeset changes and converts to a plain map, removing the
    schema metadata that `insert_all` doesn't need.
    """
    @spec to_entries([changeset()]) :: [map()]
    def to_entries(changesets) when is_list(changesets) do
      Enum.map(changesets, &changeset_to_entry/1)
    end

    defp changeset_to_entry(%Ecto.Changeset{} = changeset) do
      changeset
      |> Ecto.Changeset.apply_changes()
      |> Map.from_struct()
      |> Map.drop([:__meta__])
    end

    @doc """
    Group a list of changesets by their schema module.

    Returns a map where keys are schema modules and values are lists of
    changesets for that schema.

    ## Example

        EctoFx.group_by_schema(changesets)
        # => %{User => [cs1, cs2], Order => [cs3]}
    """
    @spec group_by_schema([changeset()]) :: %{module() => [changeset()]}
    def group_by_schema(changesets) when is_list(changesets) do
      Enum.group_by(changesets, &get_schema/1)
    end

    @doc """
    Group all captured changes by schema module.

    Takes the output of `capture/1` and returns a nested map where the outer
    keys are schema modules and inner keys are operation types.

    ## Example

        EctoFx.group_all_by_schema(%{inserts: [...], updates: [...], deletes: [...]})
        # => %{
        #   User => %{inserts: [...], updates: [...], deletes: []},
        #   Order => %{inserts: [], updates: [], deletes: [...]}
        # }
    """
    @spec group_all_by_schema(captured_changes()) :: %{module() => captured_changes()}
    def group_all_by_schema(%{inserts: inserts, updates: updates, deletes: deletes}) do
      # Get all schemas present across all operation types
      all_schemas =
        [inserts, updates, deletes]
        |> Enum.flat_map(&Enum.map(&1, fn cs -> get_schema(cs) end))
        |> Enum.uniq()

      # Group each operation type by schema
      inserts_by_schema = group_by_schema(inserts)
      updates_by_schema = group_by_schema(updates)
      deletes_by_schema = group_by_schema(deletes)

      # Build result map with all schemas
      Map.new(all_schemas, fn schema ->
        {schema,
         %{
           inserts: Map.get(inserts_by_schema, schema, []),
           updates: Map.get(updates_by_schema, schema, []),
           deletes: Map.get(deletes_by_schema, schema, [])
         }}
      end)
    end

    defp get_schema(%Ecto.Changeset{data: %schema{}}), do: schema
    defp get_schema(%schema{}), do: schema

    # ============================================================================
    # Handler/Algebra Delegation
    # ============================================================================

    @doc """
    Add the Ecto effect handler and algebra to a pipeline.

    ## Examples

        # Basic usage
        computation
        |> EctoFx.run(MyApp.Repo)
        |> Run.run()

        # With query registry
        computation
        |> EctoFx.run(MyApp.Repo, %{MyQueries => :direct})
        |> Run.run()
    """
    @spec run(any(), module(), map()) :: any()
    defdelegate run(computation_or_builder, repo, registry \\ %{}),
      to: Freyja.Effects.EctoFx.Handler

    @doc """
    Create initial handler state. Delegates to `EctoFx.Handler.new/2`.
    """
    @spec new(module(), map()) :: Freyja.Effects.EctoFx.Handler.State.t()
    defdelegate new(repo, registry \\ %{}), to: Freyja.Effects.EctoFx.Handler
  end
end
