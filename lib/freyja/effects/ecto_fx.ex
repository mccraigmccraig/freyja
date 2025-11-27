if Code.ensure_loaded?(Ecto) do
  # ============================================================================
  # Internal Operations Module (defined first due to compile-time struct usage)
  # ============================================================================

  defmodule Freyja.Effects.EctoFx.Internal do
    @moduledoc """
    Internal effect operations for EctoFx.

    **This module is not part of the public API.** These operations are used
    internally by the EctoFx algebra to elaborate higher-order operations
    (transaction, capture) into first-order effects.

    Do not use these operations directly in application code - use the
    higher-order operations `EctoFx.transaction/2` and `EctoFx.capture/1` instead.
    """

    import Freyja.Freer.Sig.DefEffectStruct
    alias Freyja.Freer

    # Transaction control
    def_effect_struct(BeginTransaction, opts: [])
    def_effect_struct(CommitTransaction, [])
    def_effect_struct(RollbackTransaction, [])

    # Capture control
    def_effect_struct(BeginCapture, [])
    def_effect_struct(FinishCapture, ref: nil, mode: :commit)

    @typedoc "Repo operation options"
    @type opts :: keyword()

    @doc false
    @spec begin_transaction(opts()) :: Freer.t()
    def begin_transaction(opts \\ []) do
      %BeginTransaction{opts: opts}
      |> Freer.send_effect()
    end

    @doc false
    @spec commit_transaction() :: Freer.t()
    def commit_transaction do
      %CommitTransaction{}
      |> Freer.send_effect()
    end

    @doc false
    @spec rollback_transaction() :: Freer.t()
    def rollback_transaction do
      %RollbackTransaction{}
      |> Freer.send_effect()
    end

    @doc false
    @spec begin_capture() :: Freer.t()
    def begin_capture do
      %BeginCapture{}
      |> Freer.send_effect()
    end

    @doc false
    @spec finish_capture(non_neg_integer(), :commit | :abort) :: Freer.t()
    def finish_capture(ref, mode) when mode in [:commit, :abort] do
      %FinishCapture{ref: ref, mode: mode}
      |> Freer.send_effect()
    end
  end

  # ============================================================================
  # Main EctoFx Module
  # ============================================================================

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
    alias Freyja.Freer.Impl
    alias Freyja.Freer.Impure
    alias Freyja.Run.RunState
    alias Freyja.Effects.EctoFx.Internal

    @behaviour Freyja.Hefty.Algebra
    @behaviour Freyja.Freer.EffectHandler

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

    ## Example

        {result, changes} <- EctoFx.capture(
          hefty do
            _ <- EctoFx.change(:insert, user_changeset)
            _ <- EctoFx.change(:update, order_changeset)
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

        Ecto.group_by_schema(changesets)
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

        Ecto.group_all_by_schema(%{inserts: [...], updates: [...], deletes: [...]})
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
    # Handler State
    # ============================================================================

    defmodule State do
      @moduledoc """
      Handler state for the unified Ecto effect.

      Contains:
      - `repo` - The Ecto.Repo module for database operations
      - `registry` - Query routing registry (maps modules to resolvers)
      - `conn` - Database connection when inside a transaction
      - `capture` - Capture context when capturing changes
      - `next_capture_ref` - Counter for capture scope references
      """

      @enforce_keys [:repo]
      defstruct [
        :repo,
        registry: %{},
        conn: nil,
        capture: nil,
        next_capture_ref: 1
      ]

      @type t :: %__MODULE__{
              repo: module(),
              registry: map(),
              conn: DBConnection.conn() | nil,
              capture: map() | nil,
              next_capture_ref: non_neg_integer()
            }
    end

    @doc """
    Create initial handler state.

    ## Parameters

    - `repo` - The Ecto.Repo module (required)
    - `registry` - Query routing registry (optional, defaults to empty map)

    ## Registry Format

    The registry maps query modules to resolvers:

    - `:direct` - Call `apply(mod, name, [params])`
    - `function` (arity 3) - `fun.(mod, name, params)`
    - `{module, function}` - `apply(module, function, [mod, name, params])`
    - `module` - `module.handle_query(mod, name, params)`
    """
    @spec new(module(), map()) :: State.t()
    def new(repo, registry \\ %{}) when is_atom(repo) do
      %State{repo: repo, registry: registry}
    end

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
    def run(computation_or_builder, repo, registry \\ %{}) do
      state = new(repo, registry)
      Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, state)
    end

    # ============================================================================
    # EffectHandler Implementation
    # ============================================================================

    @impl Freyja.Freer.EffectHandler
    def handles?(%Impure{sig: sig}, _state) do
      sig == __MODULE__ or sig == Freyja.Effects.EctoFx.Internal
    end

    @impl Freyja.Freer.EffectHandler
    def interpret(%Impure{sig: sig, data: op, q: q}, _handler_key, state, %RunState{})
        when sig == __MODULE__ or sig == Freyja.Effects.EctoFx.Internal do
      {result, new_state} = execute(state, op)

      case result do
        {:ok, value} ->
          {Impl.q_apply(q, value), new_state}

        {:error, reason} ->
          error = Freyja.Effects.Throw.throw_error(reason)
          {Impl.bindp(error, q), new_state}
      end
    end

    # Query execution
    defp execute(%State{registry: registry, conn: conn, repo: repo} = state, %Query{} = query) do
      case dispatch_query(registry, query, conn, repo) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    end

    # Single mutations
    defp execute(%State{repo: repo, conn: conn} = state, %Insert{changeset: cs, opts: opts}) do
      opts = maybe_add_conn(opts, conn)

      case repo.insert(cs, opts) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, changeset} -> {{:error, {:changeset_error, changeset}}, state}
      end
    end

    defp execute(%State{repo: repo, conn: conn} = state, %Update{changeset: cs, opts: opts}) do
      opts = maybe_add_conn(opts, conn)

      case repo.update(cs, opts) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, changeset} -> {{:error, {:changeset_error, changeset}}, state}
      end
    end

    defp execute(%State{repo: repo, conn: conn} = state, %Delete{
           struct_or_changeset: soc,
           opts: opts
         }) do
      opts = maybe_add_conn(opts, conn)

      case repo.delete(soc, opts) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, changeset} -> {{:error, {:changeset_error, changeset}}, state}
      end
    end

    defp execute(%State{repo: repo, conn: conn} = state, %InsertOrUpdate{
           changeset: cs,
           opts: opts
         }) do
      opts = maybe_add_conn(opts, conn)

      case repo.insert_or_update(cs, opts) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, changeset} -> {{:error, {:changeset_error, changeset}}, state}
      end
    end

    # Bulk mutations
    defp execute(%State{repo: repo, conn: conn} = state, %InsertAll{
           schema: schema,
           entries: entries,
           opts: opts
         }) do
      opts = maybe_add_conn(opts, conn)
      result = repo.insert_all(schema, entries, opts)
      {{:ok, result}, state}
    end

    defp execute(%State{repo: repo, conn: conn} = state, %UpdateAll{
           queryable: q,
           updates: updates,
           opts: opts
         }) do
      opts = maybe_add_conn(opts, conn)
      result = repo.update_all(q, updates, opts)
      {{:ok, result}, state}
    end

    defp execute(%State{repo: repo, conn: conn} = state, %DeleteAll{queryable: q, opts: opts}) do
      opts = maybe_add_conn(opts, conn)
      result = repo.delete_all(q, opts)
      {{:ok, result}, state}
    end

    # Change recording
    defp execute(%State{capture: nil} = _state, %Change{}) do
      raise RuntimeError, "EctoFx.change called outside of EctoFx.capture scope"
    end

    defp execute(%State{capture: capture} = state, %Change{op: op, changeset: cs}) do
      list_key =
        case op do
          :insert -> :inserts
          :update -> :updates
          :delete -> :deletes
        end

      updated_capture = Map.update!(capture, list_key, &[cs | &1])
      {{:ok, :ok}, %{state | capture: updated_capture}}
    end

    # Transaction control
    #
    # NOTE: Transaction support is currently limited. Ecto's Repo.transaction/2
    # uses a callback-based approach that doesn't integrate well with Freyja's
    # continuation-based model. For now, we track transaction state but don't
    # actually acquire a dedicated connection.
    #
    # For real transaction support, consider:
    # 1. Using Ecto.Adapters.SQL.Sandbox in tests
    # 2. Using raw SQL BEGIN/COMMIT/ROLLBACK via Ecto.Adapters.SQL.query
    # 3. Structuring code to use Repo.transaction at the boundary
    #
    # Future enhancement: Use DBConnection.run/3 to acquire a connection and
    # pass it via the :conn option to all Repo operations within the transaction.

    defp execute(%State{conn: nil} = state, %Internal.BeginTransaction{opts: _opts}) do
      # Mark that we're in a transaction (semantic tracking for now)
      # TODO: Implement proper connection acquisition when db_connection is available
      {{:ok, :ok}, %{state | conn: :in_transaction}}
    end

    defp execute(%State{conn: :in_transaction} = _state, %Internal.BeginTransaction{}) do
      raise RuntimeError, "Nested transactions are not supported"
    end

    defp execute(%State{conn: :in_transaction} = state, %Internal.CommitTransaction{}) do
      # TODO: Implement proper commit when using real connection
      {{:ok, :ok}, %{state | conn: nil}}
    end

    defp execute(%State{conn: nil} = _state, %Internal.CommitTransaction{}) do
      raise RuntimeError, "CommitTransaction called outside of transaction"
    end

    defp execute(%State{conn: :in_transaction} = state, %Internal.RollbackTransaction{}) do
      # TODO: Implement proper rollback when using real connection
      {{:ok, :ok}, %{state | conn: nil}}
    end

    defp execute(%State{conn: nil} = _state, %Internal.RollbackTransaction{}) do
      raise RuntimeError, "RollbackTransaction called outside of transaction"
    end

    # Capture control
    defp execute(%State{capture: %{}} = _state, %Internal.BeginCapture{}) do
      raise ArgumentError, "EctoFx.capture is already active - nested captures not supported"
    end

    defp execute(%State{next_capture_ref: ref} = state, %Internal.BeginCapture{}) do
      capture = %{ref: ref, inserts: [], updates: [], deletes: []}
      {{:ok, ref}, %{state | capture: capture, next_capture_ref: ref + 1}}
    end

    defp execute(%State{capture: nil} = _state, %Internal.FinishCapture{}) do
      raise ArgumentError, "EctoFx.capture stack underflow"
    end

    defp execute(%State{capture: %{ref: active_ref}} = _state, %Internal.FinishCapture{ref: ref})
         when ref != active_ref do
      raise ArgumentError,
            "EctoFx.capture closed out of order: expected ref #{active_ref}, got #{ref}"
    end

    defp execute(%State{capture: capture} = state, %Internal.FinishCapture{mode: :commit}) do
      result = %{
        inserts: Enum.reverse(capture.inserts),
        updates: Enum.reverse(capture.updates),
        deletes: Enum.reverse(capture.deletes)
      }

      {{:ok, result}, %{state | capture: nil}}
    end

    defp execute(%State{} = state, %Internal.FinishCapture{mode: :abort}) do
      empty_result = %{inserts: [], updates: [], deletes: []}
      {{:ok, empty_result}, %{state | capture: nil}}
    end

    # Query dispatch helpers
    defp dispatch_query(registry, %Query{mod: mod} = query, conn, repo) when is_map(registry) do
      case Map.fetch(registry, mod) do
        {:ok, resolver} -> {:ok, invoke_query(resolver, query, conn, repo)}
        :error -> {:error, {:unknown_query_module, mod}}
      end
    end

    defp dispatch_query(resolver, query, conn, repo) do
      {:ok, invoke_query(resolver, query, conn, repo)}
    rescue
      exception -> {:error, {:query_failed, exception}}
    end

    defp invoke_query(:direct, %Query{mod: mod, name: name, params: params}, _conn, _repo) do
      apply(mod, name, [params])
    end

    defp invoke_query(fun, %Query{mod: mod, name: name, params: params}, _conn, _repo)
         when is_function(fun, 3) do
      fun.(mod, name, params)
    end

    defp invoke_query(
           {module, function},
           %Query{mod: mod, name: name, params: params},
           _conn,
           _repo
         ) do
      apply(module, function, [mod, name, params])
    end

    defp invoke_query(module, %Query{mod: mod, name: name, params: params}, _conn, _repo)
         when is_atom(module) do
      if function_exported?(module, :handle_query, 3) do
        apply(module, :handle_query, [mod, name, params])
      else
        raise ArgumentError,
              "#{inspect(module)} must export handle_query/3 to be used as a Query resolver"
      end
    end

    defp maybe_add_conn(opts, nil), do: opts
    # :in_transaction is a marker, not an actual connection
    defp maybe_add_conn(opts, :in_transaction), do: opts
    defp maybe_add_conn(opts, conn), do: Keyword.put(opts, :conn, conn)

    # ============================================================================
    # Algebra Implementation
    # ============================================================================

    @impl Freyja.Hefty.Algebra
    def handles?(sig) when sig == __MODULE__, do: true
    def handles?(_), do: false

    @impl Freyja.Hefty.Algebra
    def elaborate(%Transaction{opts: opts}, psi, k, _elaborator) do
      inner = Map.fetch!(psi, :inner)

      use Freyja.Syntax

      con do
        _ <- Internal.begin_transaction(opts)

        # Interpose on Throw to rollback on error
        guarded_inner = attach_rollback_on_throw(inner)

        result <- guarded_inner
        _ <- Internal.commit_transaction()
        k.(result)
      end
    end

    def elaborate(%Capture{}, psi, k, _elaborator) do
      inner = Map.fetch!(psi, :inner)

      use Freyja.Syntax

      con do
        ref <- Internal.begin_capture()

        # Interpose on Throw to abort capture on error
        guarded_inner = attach_abort_on_throw(inner, ref)

        result <- guarded_inner
        changes <- Internal.finish_capture(ref, :commit)
        k.({result, changes})
      end
    end

    defp attach_rollback_on_throw(inner) do
      alias Freyja.Effects.Throw
      alias Freyja.Effects.Throw.ThrowOp
      alias Freyja.Freer.Interpose

      use Freyja.Syntax

      Interpose.interpose_with(inner, Throw, fn %ThrowOp{error: err}, _cont ->
        con do
          _ <- Internal.rollback_transaction()
          Throw.throw_error(err)
        end
      end)
    end

    defp attach_abort_on_throw(inner, ref) do
      alias Freyja.Effects.Throw
      alias Freyja.Effects.Throw.ThrowOp
      alias Freyja.Freer.Interpose

      use Freyja.Syntax

      Interpose.interpose_with(inner, Throw, fn %ThrowOp{error: err}, _cont ->
        con do
          _ <- Internal.finish_capture(ref, :abort)
          Throw.throw_error(err)
        end
      end)
    end
  end

  # ============================================================================
  # Test Handler
  # ============================================================================

  defmodule Freyja.Effects.EctoFx.TestHandler do
    @moduledoc """
    Test handler for `Freyja.Effects.EctoFx` that doesn't require a database.

    Useful for testing effectful code without database setup. Provides canned
    responses and tracks all operations for assertions.

    ## Usage

        # Create handler state with optional stubs
        state = Ecto.TestHandler.new()
        |> Ecto.TestHandler.stub_query(MyQueries, :find_user, %{id: 1}, {:ok, %User{id: 1}})
        |> Ecto.TestHandler.stub_insert(User, fn changeset ->
          {:ok, %User{id: 1, name: Ecto.Changeset.get_field(changeset, :name)}}
        end)

        computation
        |> Ecto.TestHandler.run(state)
        |> Run.run()

    ## Tracking Operations

    After running, you can inspect all operations that were attempted:

        outcome = Run.run(builder)
        state = outcome.outputs[Ecto.TestHandler]
        ops = Ecto.TestHandler.get_operations(state)
    """

    alias Freyja.Effects.EctoFx, as: EctoEffect
    alias Freyja.Effects.EctoFx.Query
    alias Freyja.Effects.EctoFx.{Insert, Update, Delete, InsertOrUpdate}
    alias Freyja.Effects.EctoFx.{InsertAll, UpdateAll, DeleteAll}
    alias Freyja.Effects.EctoFx.Change
    alias Freyja.Effects.EctoFx.Internal
    alias Freyja.Effects.EctoFx.Internal.{BeginCapture, FinishCapture}

    alias Freyja.Effects.EctoFx.Internal.{
      BeginTransaction,
      CommitTransaction,
      RollbackTransaction
    }

    alias Freyja.Effects.Throw
    alias Freyja.Freer.Impl
    alias Freyja.Freer.Impure
    alias Freyja.Run.RunState

    @behaviour Freyja.Hefty.Algebra
    @behaviour Freyja.Freer.EffectHandler

    defmodule State do
      @moduledoc false
      defstruct query_stubs: %{},
                mutation_stubs: %{},
                operations: [],
                capture: nil,
                next_capture_ref: 1,
                in_transaction: false
    end

    @doc "Create a new test handler state."
    def new, do: %State{}

    @doc "Stub a query response."
    def stub_query(%State{query_stubs: stubs} = state, mod, name, params, result) do
      key = EctoEffect.query_key(mod, name, params)
      %{state | query_stubs: Map.put(stubs, key, result)}
    end

    @doc "Stub insert operations for a schema."
    def stub_insert(%State{mutation_stubs: stubs} = state, schema, fun)
        when is_function(fun, 1) do
      %{state | mutation_stubs: Map.put(stubs, {:insert, schema}, fun)}
    end

    @doc "Stub update operations for a schema."
    def stub_update(%State{mutation_stubs: stubs} = state, schema, fun)
        when is_function(fun, 1) do
      %{state | mutation_stubs: Map.put(stubs, {:update, schema}, fun)}
    end

    @doc "Stub delete operations for a schema."
    def stub_delete(%State{mutation_stubs: stubs} = state, schema, fun)
        when is_function(fun, 1) do
      %{state | mutation_stubs: Map.put(stubs, {:delete, schema}, fun)}
    end

    @doc "Get all recorded operations."
    def get_operations(%State{operations: ops}), do: Enum.reverse(ops)

    defp record_op(%State{operations: ops} = state, op) do
      %{state | operations: [op | ops]}
    end

    defp get_schema(%Ecto.Changeset{data: %schema{}}), do: schema
    defp get_schema(%schema{}), do: schema

    # Algebra implementation (delegates to main module)
    @impl Freyja.Hefty.Algebra
    def handles?(sig) when sig == EctoEffect, do: true
    def handles?(_), do: false

    @impl Freyja.Hefty.Algebra
    defdelegate elaborate(op, psi, k, elaborator), to: EctoEffect

    # Handler implementation
    @impl Freyja.Freer.EffectHandler
    def handles?(%Impure{sig: sig}, _state), do: sig == EctoEffect or sig == Internal

    @impl Freyja.Freer.EffectHandler
    def interpret(%Impure{sig: sig, data: op, q: q}, _handler_key, state, %RunState{})
        when sig == EctoEffect or sig == Internal do
      {result, new_state} = execute(state, op)

      case result do
        {:ok, value} ->
          {Impl.q_apply(q, value), new_state}

        {:error, reason} ->
          error = Throw.throw_error(reason)
          {Impl.bindp(error, q), new_state}
      end
    end

    # Query
    defp execute(
           %State{query_stubs: stubs} = state,
           %Query{mod: mod, name: name, params: params} = op
         ) do
      state = record_op(state, op)
      key = EctoEffect.query_key(mod, name, params)

      case Map.fetch(stubs, key) do
        {:ok, result} -> {{:ok, result}, state}
        :error -> {{:error, {:query_not_stubbed, key}}, state}
      end
    end

    # Mutations
    defp execute(%State{mutation_stubs: stubs} = state, %Insert{changeset: cs} = op) do
      state = record_op(state, op)
      schema = get_schema(cs)

      result =
        case Map.get(stubs, {:insert, schema}) do
          nil -> default_insert(cs)
          fun -> fun.(cs)
        end

      case result do
        {:ok, value} -> {{:ok, value}, state}
        {:error, reason} -> {{:error, {:changeset_error, reason}}, state}
      end
    end

    defp execute(%State{mutation_stubs: stubs} = state, %Update{changeset: cs} = op) do
      state = record_op(state, op)
      schema = get_schema(cs)

      result =
        case Map.get(stubs, {:update, schema}) do
          nil -> default_update(cs)
          fun -> fun.(cs)
        end

      case result do
        {:ok, value} -> {{:ok, value}, state}
        {:error, reason} -> {{:error, {:changeset_error, reason}}, state}
      end
    end

    defp execute(%State{mutation_stubs: stubs} = state, %Delete{struct_or_changeset: soc} = op) do
      state = record_op(state, op)
      schema = get_schema(soc)

      result =
        case Map.get(stubs, {:delete, schema}) do
          nil -> default_delete(soc)
          fun -> fun.(soc)
        end

      case result do
        {:ok, value} -> {{:ok, value}, state}
        {:error, reason} -> {{:error, {:changeset_error, reason}}, state}
      end
    end

    defp execute(%State{mutation_stubs: stubs} = state, %InsertOrUpdate{changeset: cs} = op) do
      state = record_op(state, op)
      schema = get_schema(cs)

      result =
        case Map.get(stubs, {:insert_or_update, schema}) do
          nil -> default_insert(cs)
          fun -> fun.(cs)
        end

      case result do
        {:ok, value} -> {{:ok, value}, state}
        {:error, reason} -> {{:error, {:changeset_error, reason}}, state}
      end
    end

    defp execute(state, %InsertAll{entries: entries} = op) do
      state = record_op(state, op)
      {{:ok, {length(entries), nil}}, state}
    end

    defp execute(state, %UpdateAll{} = op) do
      state = record_op(state, op)
      {{:ok, {0, nil}}, state}
    end

    defp execute(state, %DeleteAll{} = op) do
      state = record_op(state, op)
      {{:ok, {0, nil}}, state}
    end

    # Change recording
    defp execute(%State{capture: nil} = _state, %Change{}) do
      raise RuntimeError, "EctoFx.change called outside of EctoFx.capture scope"
    end

    defp execute(%State{capture: capture} = state, %Change{op: op_type, changeset: cs} = op) do
      state = record_op(state, op)

      list_key =
        case op_type do
          :insert -> :inserts
          :update -> :updates
          :delete -> :deletes
        end

      updated_capture = Map.update!(capture, list_key, &[cs | &1])
      {{:ok, :ok}, %{state | capture: updated_capture}}
    end

    # Transaction control
    defp execute(%State{in_transaction: true} = _state, %BeginTransaction{}) do
      raise RuntimeError, "Nested transactions are not supported"
    end

    defp execute(state, %BeginTransaction{} = op) do
      state = record_op(state, op)
      {{:ok, :ok}, %{state | in_transaction: true}}
    end

    defp execute(%State{in_transaction: false} = _state, %CommitTransaction{}) do
      raise RuntimeError, "CommitTransaction called outside of transaction"
    end

    defp execute(state, %CommitTransaction{} = op) do
      state = record_op(state, op)
      {{:ok, :ok}, %{state | in_transaction: false}}
    end

    defp execute(%State{in_transaction: false} = _state, %RollbackTransaction{}) do
      raise RuntimeError, "RollbackTransaction called outside of transaction"
    end

    defp execute(state, %RollbackTransaction{} = op) do
      state = record_op(state, op)
      {{:ok, :ok}, %{state | in_transaction: false}}
    end

    # Capture control
    defp execute(%State{capture: %{}} = _state, %BeginCapture{}) do
      raise ArgumentError, "EctoFx.capture is already active - nested captures not supported"
    end

    defp execute(%State{next_capture_ref: ref} = state, %BeginCapture{} = op) do
      state = record_op(state, op)
      capture = %{ref: ref, inserts: [], updates: [], deletes: []}
      {{:ok, ref}, %{state | capture: capture, next_capture_ref: ref + 1}}
    end

    defp execute(%State{capture: nil} = _state, %FinishCapture{}) do
      raise ArgumentError, "EctoFx.capture stack underflow"
    end

    defp execute(%State{capture: %{ref: active_ref}} = _state, %FinishCapture{ref: ref})
         when ref != active_ref do
      raise ArgumentError,
            "EctoFx.capture closed out of order: expected ref #{active_ref}, got #{ref}"
    end

    defp execute(%State{capture: capture} = state, %FinishCapture{mode: :commit} = op) do
      state = record_op(state, op)

      result = %{
        inserts: Enum.reverse(capture.inserts),
        updates: Enum.reverse(capture.updates),
        deletes: Enum.reverse(capture.deletes)
      }

      {{:ok, result}, %{state | capture: nil}}
    end

    defp execute(state, %FinishCapture{mode: :abort} = op) do
      state = record_op(state, op)
      empty_result = %{inserts: [], updates: [], deletes: []}
      {{:ok, empty_result}, %{state | capture: nil}}
    end

    # Default implementations
    defp default_insert(changeset) do
      if changeset.valid? do
        {:ok, Ecto.Changeset.apply_changes(changeset)}
      else
        {:error, changeset}
      end
    end

    defp default_update(changeset) do
      if changeset.valid? do
        {:ok, Ecto.Changeset.apply_changes(changeset)}
      else
        {:error, changeset}
      end
    end

    defp default_delete(struct_or_changeset) do
      case struct_or_changeset do
        %Ecto.Changeset{} = cs -> {:ok, Ecto.Changeset.apply_changes(cs)}
        struct -> {:ok, struct}
      end
    end

    @doc """
    Add the test handler to a pipeline.
    """
    @spec run(any(), State.t()) :: any()
    def run(computation_or_builder, %State{} = state \\ new()) do
      Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, state)
    end
  end
end
