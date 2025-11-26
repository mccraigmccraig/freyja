if Code.ensure_loaded?(Ecto) do
  defmodule Freyja.Effects.Ecto.Mutate do
    @moduledoc """
    Ecto-specific mutation effect for database operations.

    This effect provides a clean interface for Ecto repository operations,
    working directly with `Ecto.Changeset` structs. It complements the generic
    `Freyja.Effects.Query` effect by providing type-safe mutation operations.

    ## Operations

    Single-record operations (work with Ecto.Changeset):
      * `insert(changeset)` - Insert a new record
      * `update(changeset)` - Update an existing record
      * `delete(struct_or_changeset)` - Delete a record
      * `insert_or_update(changeset)` - Insert or update based on primary key

    Bulk operations:
      * `insert_all(schema, entries, opts)` - Insert multiple records
      * `update_all(queryable, updates, opts)` - Update multiple records
      * `delete_all(queryable, opts)` - Delete multiple records

    ## Handler Setup

    The handler requires an Ecto.Repo module:

        computation
        |> Mutate.Handler.run(MyApp.Repo)
        |> Run.run()

    ## Example

        use Freyja.Syntax
        alias Freyja.Effects.Ecto.Mutate

        defhefty update_user(user, attrs) do
          changeset = User.changeset(user, attrs)
          updated <- Mutate.update(changeset)
          return(updated)
        end

    ## Integration with Changes

        defhefty process_batch(users, update_fn) do
          {results, changesets} <- Changes.capture(FxList.fx_map(users, update_fn))

          # Apply all captured changesets
          _ <- FxList.fx_map(changesets, &Mutate.update/1)

          return(results)
        end
    """

    import Freyja.Freer.Sig.DefEffectStruct
    alias Freyja.Freer

    # Single-record operations
    def_effect_struct(Insert, changeset: nil, opts: [])
    def_effect_struct(Update, changeset: nil, opts: [])
    def_effect_struct(Delete, struct_or_changeset: nil, opts: [])
    def_effect_struct(InsertOrUpdate, changeset: nil, opts: [])

    # Bulk operations
    def_effect_struct(InsertAll, schema: nil, entries: [], opts: [])
    def_effect_struct(UpdateAll, queryable: nil, updates: [], opts: [])
    def_effect_struct(DeleteAll, queryable: nil, opts: [])

    @typedoc "Ecto changeset"
    @type changeset :: Ecto.Changeset.t()

    @typedoc "Ecto schema module"
    @type schema :: module()

    @typedoc "Ecto queryable (schema, query, or table name)"
    @type queryable :: Ecto.Queryable.t()

    @typedoc "Repo operation options"
    @type opts :: keyword()

    # Single-record operations

    @doc """
    Insert a new record from a changeset.

    Returns the inserted struct on success, or raises via Throw effect on error.
    """
    @spec insert(changeset(), opts()) :: Freer.t()
    def insert(changeset, opts \\ []) do
      %Insert{changeset: changeset, opts: opts} |> Freer.send_effect()
    end

    @doc """
    Update an existing record from a changeset.

    Returns the updated struct on success, or raises via Throw effect on error.
    """
    @spec update(changeset(), opts()) :: Freer.t()
    def update(changeset, opts \\ []) do
      %Update{changeset: changeset, opts: opts} |> Freer.send_effect()
    end

    @doc """
    Delete a record.

    Accepts either a struct or a changeset. Returns the deleted struct on success.
    """
    @spec delete(struct() | changeset(), opts()) :: Freer.t()
    def delete(struct_or_changeset, opts \\ []) do
      %Delete{struct_or_changeset: struct_or_changeset, opts: opts} |> Freer.send_effect()
    end

    @doc """
    Insert or update a record based on whether it has a primary key.

    Returns the inserted/updated struct on success.
    """
    @spec insert_or_update(changeset(), opts()) :: Freer.t()
    def insert_or_update(changeset, opts \\ []) do
      %InsertOrUpdate{changeset: changeset, opts: opts} |> Freer.send_effect()
    end

    # Bulk operations

    @doc """
    Insert multiple records at once.

    Returns `{count, nil | [struct]}` where count is the number of inserted records.
    The second element depends on the `:returning` option.
    """
    @spec insert_all(schema(), [map() | keyword()], opts()) :: Freer.t()
    def insert_all(schema, entries, opts \\ []) do
      %InsertAll{schema: schema, entries: entries, opts: opts} |> Freer.send_effect()
    end

    @doc """
    Update multiple records matching a query.

    Returns `{count, nil | [struct]}` where count is the number of updated records.
    """
    @spec update_all(queryable(), keyword(), opts()) :: Freer.t()
    def update_all(queryable, updates, opts \\ []) do
      %UpdateAll{queryable: queryable, updates: updates, opts: opts} |> Freer.send_effect()
    end

    @doc """
    Delete multiple records matching a query.

    Returns `{count, nil | [struct]}` where count is the number of deleted records.
    """
    @spec delete_all(queryable(), opts()) :: Freer.t()
    def delete_all(queryable, opts \\ []) do
      %DeleteAll{queryable: queryable, opts: opts} |> Freer.send_effect()
    end
  end

  defmodule Freyja.Effects.Ecto.Mutate.Handler do
    @moduledoc """
    Handler for `Freyja.Effects.Ecto.Mutate` that delegates to an Ecto.Repo.

    ## Usage

        computation
        |> Mutate.Handler.run(MyApp.Repo)
        |> Run.run()

    ## Error Handling

    On success, returns the result directly. On error (invalid changeset),
    propagates the error via `Freyja.Effects.Throw.throw_error/1` with the
    changeset as the error value.
    """

    alias Freyja.Effects.Ecto.Mutate
    alias Freyja.Effects.Ecto.Mutate.{Insert, Update, Delete, InsertOrUpdate}
    alias Freyja.Effects.Ecto.Mutate.{InsertAll, UpdateAll, DeleteAll}
    alias Freyja.Effects.Throw
    alias Freyja.Freer
    alias Freyja.Freer.Impl
    alias Freyja.Freer.Impure
    alias Freyja.Run.RunState

    @behaviour Freyja.Freer.EffectHandler

    @impl Freyja.Freer.EffectHandler
    def handles?(%Impure{sig: sig}, _state), do: sig == Mutate

    @impl Freyja.Freer.EffectHandler
    def interpret(%Impure{sig: Mutate, data: op, q: q}, _handler_key, repo, %RunState{}) do
      case execute(repo, op) do
        {:ok, result} ->
          {Impl.q_apply(q, result), repo}

        {:error, changeset} ->
          error = Throw.throw_error({:changeset_error, changeset})
          {Impl.bindp(error, q), repo}
      end
    end

    defp execute(repo, %Insert{changeset: changeset, opts: opts}) do
      repo.insert(changeset, opts)
    end

    defp execute(repo, %Update{changeset: changeset, opts: opts}) do
      repo.update(changeset, opts)
    end

    defp execute(repo, %Delete{struct_or_changeset: struct_or_changeset, opts: opts}) do
      repo.delete(struct_or_changeset, opts)
    end

    defp execute(repo, %InsertOrUpdate{changeset: changeset, opts: opts}) do
      repo.insert_or_update(changeset, opts)
    end

    defp execute(repo, %InsertAll{schema: schema, entries: entries, opts: opts}) do
      result = repo.insert_all(schema, entries, opts)
      {:ok, result}
    end

    defp execute(repo, %UpdateAll{queryable: queryable, updates: updates, opts: opts}) do
      result = repo.update_all(queryable, updates, opts)
      {:ok, result}
    end

    defp execute(repo, %DeleteAll{queryable: queryable, opts: opts}) do
      result = repo.delete_all(queryable, opts)
      {:ok, result}
    end

    @doc """
    Add the Mutate handler to a pipeline with the given Ecto.Repo.
    """
    @spec run(any(), module()) :: any()
    def run(computation_or_builder, repo) when is_atom(repo) do
      Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, repo)
    end
  end

  defmodule Freyja.Effects.Ecto.Mutate.TestHandler do
    @moduledoc """
    Test handler for `Freyja.Effects.Ecto.Mutate` that doesn't require a database.

    Useful for testing effectful code without database setup. Provides canned
    responses and tracks all mutations for assertions.

    ## Usage

        # Create handler state with optional canned responses
        state = Mutate.TestHandler.new()
        |> Mutate.TestHandler.stub_insert(User, fn changeset ->
          {:ok, %User{id: 1, name: Ecto.Changeset.get_field(changeset, :name)}}
        end)

        computation
        |> Mutate.TestHandler.run(state)
        |> Run.run()

    ## Tracking Mutations

    After running, you can inspect all mutations that were attempted:

        outcome = Run.run(builder)
        state = outcome.outputs[Mutate.TestHandler]
        mutations = Mutate.TestHandler.get_mutations(state)
    """

    alias Freyja.Effects.Ecto.Mutate
    alias Freyja.Effects.Ecto.Mutate.{Insert, Update, Delete, InsertOrUpdate}
    alias Freyja.Effects.Ecto.Mutate.{InsertAll, UpdateAll, DeleteAll}
    alias Freyja.Effects.Throw
    alias Freyja.Freer
    alias Freyja.Freer.Impl
    alias Freyja.Freer.Impure
    alias Freyja.Run.RunState

    @behaviour Freyja.Freer.EffectHandler

    defmodule State do
      @moduledoc false
      defstruct stubs: %{}, mutations: []
    end

    @doc """
    Create a new test handler state.
    """
    def new, do: %State{}

    @doc """
    Stub insert operations for a schema.

    The function receives the changeset and should return `{:ok, struct}` or
    `{:error, changeset}`.
    """
    def stub_insert(%State{} = state, schema, fun) when is_function(fun, 1) do
      put_stub(state, {:insert, schema}, fun)
    end

    @doc """
    Stub update operations for a schema.
    """
    def stub_update(%State{} = state, schema, fun) when is_function(fun, 1) do
      put_stub(state, {:update, schema}, fun)
    end

    @doc """
    Stub delete operations for a schema.
    """
    def stub_delete(%State{} = state, schema, fun) when is_function(fun, 1) do
      put_stub(state, {:delete, schema}, fun)
    end

    @doc """
    Stub insert_or_update operations for a schema.
    """
    def stub_insert_or_update(%State{} = state, schema, fun) when is_function(fun, 1) do
      put_stub(state, {:insert_or_update, schema}, fun)
    end

    @doc """
    Get all recorded mutations.
    """
    def get_mutations(%State{mutations: mutations}), do: Enum.reverse(mutations)

    defp put_stub(%State{stubs: stubs} = state, key, fun) do
      %State{state | stubs: Map.put(stubs, key, fun)}
    end

    defp record_mutation(%State{mutations: mutations} = state, mutation) do
      %State{state | mutations: [mutation | mutations]}
    end

    defp get_schema(%Ecto.Changeset{data: %schema{}}), do: schema
    defp get_schema(%schema{}), do: schema

    @impl Freyja.Freer.EffectHandler
    def handles?(%Impure{sig: sig}, _state), do: sig == Mutate

    @impl Freyja.Freer.EffectHandler
    def interpret(%Impure{sig: Mutate, data: op, q: q}, _handler_key, state, %RunState{}) do
      {result, new_state} = execute(state, op)

      case result do
        {:ok, value} ->
          {Impl.q_apply(q, value), new_state}

        {:error, changeset} ->
          error = Throw.throw_error({:changeset_error, changeset})
          {Impl.bindp(error, q), new_state}
      end
    end

    defp execute(state, %Insert{changeset: changeset} = op) do
      schema = get_schema(changeset)
      state = record_mutation(state, op)

      result =
        case Map.get(state.stubs, {:insert, schema}) do
          nil -> default_insert(changeset)
          fun -> fun.(changeset)
        end

      {result, state}
    end

    defp execute(state, %Update{changeset: changeset} = op) do
      schema = get_schema(changeset)
      state = record_mutation(state, op)

      result =
        case Map.get(state.stubs, {:update, schema}) do
          nil -> default_update(changeset)
          fun -> fun.(changeset)
        end

      {result, state}
    end

    defp execute(state, %Delete{struct_or_changeset: struct_or_changeset} = op) do
      schema = get_schema(struct_or_changeset)
      state = record_mutation(state, op)

      result =
        case Map.get(state.stubs, {:delete, schema}) do
          nil -> default_delete(struct_or_changeset)
          fun -> fun.(struct_or_changeset)
        end

      {result, state}
    end

    defp execute(state, %InsertOrUpdate{changeset: changeset} = op) do
      schema = get_schema(changeset)
      state = record_mutation(state, op)

      result =
        case Map.get(state.stubs, {:insert_or_update, schema}) do
          nil -> default_insert_or_update(changeset)
          fun -> fun.(changeset)
        end

      {result, state}
    end

    defp execute(state, %InsertAll{} = op) do
      state = record_mutation(state, op)
      {{:ok, {length(op.entries), nil}}, state}
    end

    defp execute(state, %UpdateAll{} = op) do
      state = record_mutation(state, op)
      {{:ok, {0, nil}}, state}
    end

    defp execute(state, %DeleteAll{} = op) do
      state = record_mutation(state, op)
      {{:ok, {0, nil}}, state}
    end

    # Default implementations that apply changeset changes
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

    defp default_insert_or_update(changeset) do
      if changeset.valid? do
        {:ok, Ecto.Changeset.apply_changes(changeset)}
      else
        {:error, changeset}
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
