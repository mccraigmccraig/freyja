if Code.ensure_loaded?(Ecto) do
  defmodule Freyja.Effects.EctoFx.Handler do
    @moduledoc """
    Effect handler and algebra for `Freyja.Effects.EctoFx`.

    This module implements both `Freyja.Freer.EffectHandler` for first-order
    operations and `Freyja.Hefty.Algebra` for higher-order operations
    (transaction, capture).

    ## Usage

    Use `EctoFx.run/3` to add the handler to a pipeline:

        computation
        |> EctoFx.run(MyApp.Repo, query_registry)
        |> Run.run()

    This module is typically not used directly - use the functions in
    `Freyja.Effects.EctoFx` instead.
    """

    alias Freyja.Effects.EctoFx
    alias Freyja.Effects.EctoFx.Internal
    alias Freyja.Effects.EctoFx.Query
    alias Freyja.Effects.EctoFx.{Insert, Update, Delete, InsertOrUpdate}
    alias Freyja.Effects.EctoFx.{InsertAll, UpdateAll, DeleteAll}
    alias Freyja.Effects.EctoFx.Change
    alias Freyja.Effects.EctoFx.{Transaction, Capture}
    alias Freyja.Freer.Impl
    alias Freyja.Freer.Impure
    alias Freyja.Run.RunState

    @behaviour Freyja.Hefty.Algebra
    @behaviour Freyja.Freer.EffectHandler

    # These modules are optional dependencies - suppress undefined warnings
    @compile {:no_warn_undefined, [Ecto.Adapters.SQL, DBConnection.Holder]}

    # ============================================================================
    # Handler State
    # ============================================================================

    defmodule State do
      @moduledoc """
      Handler state for the unified Ecto effect.

      Contains:
      - `repo` - The Ecto.Repo module for database operations
      - `registry` - Query routing registry (maps modules to resolvers)
      - `transaction` - Transaction context when inside a transaction (for cleanup)
      - `capture` - Capture context when capturing changes
      - `next_capture_ref` - Counter for capture scope references
      """

      @enforce_keys [:repo]
      defstruct [
        :repo,
        registry: %{},
        transaction: nil,
        capture: nil,
        next_capture_ref: 1
      ]

      @type transaction_context :: %{
              pool: pid(),
              pool_ref: any()
            }

      @type t :: %__MODULE__{
              repo: module(),
              registry: map(),
              transaction: transaction_context() | nil,
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
        |> EctoFx.Handler.run(MyApp.Repo)
        |> Run.run()

        # With query registry
        computation
        |> EctoFx.Handler.run(MyApp.Repo, %{MyQueries => :direct})
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
      sig == EctoFx or sig == Internal
    end

    @impl Freyja.Freer.EffectHandler
    def interpret(%Impure{sig: sig, data: op, q: q}, _handler_key, state, %RunState{})
        when sig == EctoFx or sig == Internal do
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
    # Note: When inside a transaction, the connection is in the process dictionary
    # and Ecto will automatically use it for all operations.
    defp execute(%State{registry: registry, repo: repo} = state, %Query{} = query) do
      case dispatch_query(registry, query, repo) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    end

    # Single mutations
    defp execute(%State{repo: repo} = state, %Insert{changeset: cs, opts: opts}) do
      case repo.insert(cs, opts) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, changeset} -> {{:error, {:changeset_error, changeset}}, state}
      end
    end

    defp execute(%State{repo: repo} = state, %Update{changeset: cs, opts: opts}) do
      case repo.update(cs, opts) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, changeset} -> {{:error, {:changeset_error, changeset}}, state}
      end
    end

    defp execute(%State{repo: repo} = state, %Delete{struct_or_changeset: soc, opts: opts}) do
      case repo.delete(soc, opts) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, changeset} -> {{:error, {:changeset_error, changeset}}, state}
      end
    end

    defp execute(%State{repo: repo} = state, %InsertOrUpdate{changeset: cs, opts: opts}) do
      case repo.insert_or_update(cs, opts) do
        {:ok, result} -> {{:ok, result}, state}
        {:error, changeset} -> {{:error, {:changeset_error, changeset}}, state}
      end
    end

    # Bulk mutations
    defp execute(%State{repo: repo} = state, %InsertAll{
           schema: schema,
           entries: entries,
           opts: opts
         }) do
      result = repo.insert_all(schema, entries, opts)
      {{:ok, result}, state}
    end

    defp execute(%State{repo: repo} = state, %UpdateAll{
           queryable: q,
           updates: updates,
           opts: opts
         }) do
      result = repo.update_all(q, updates, opts)
      {{:ok, result}, state}
    end

    defp execute(%State{repo: repo} = state, %DeleteAll{queryable: q, opts: opts}) do
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
    # Real transaction support using DBConnection checkout/checkin.
    #
    # We checkout a connection from the pool, store it in the process dictionary
    # (using the same key format Ecto uses), execute BEGIN, and all subsequent
    # Repo operations automatically use that connection.
    #
    # On commit/rollback, we execute the SQL command, remove from process dict,
    # and checkin the connection back to the pool.
    #
    # Behavior:
    # - Throws inside transactions trigger rollback (via interposition)
    # - Yields inside transactions are converted to errors and trigger rollback
    #   (yielding would hold a DB connection indefinitely, which is not allowed)
    # - Nested transactions raise RuntimeError

    defp execute(%State{transaction: nil, repo: repo} = state, %Internal.BeginTransaction{
           opts: opts
         }) do
      # Get adapter metadata to find the pool
      %{pid: pool} = Ecto.Adapter.lookup_meta(repo)

      # Checkout a connection from the pool
      case DBConnection.Holder.checkout(pool, [self()], opts) do
        {:ok, pool_ref, _conn_mod, _checkin_time, _conn_state} ->
          # Create DBConnection struct and store in process dictionary
          # This is the same format Ecto uses internally
          # We use struct/2 because DBConnection's defstruct is not exported for compile-time use
          conn = struct(DBConnection, pool_ref: pool_ref, conn_ref: make_ref(), conn_mode: nil)
          Process.put({Ecto.Adapters.SQL, pool}, conn)

          # Execute BEGIN
          Ecto.Adapters.SQL.query!(repo, "BEGIN", [], opts)

          # Store context for later cleanup
          transaction = %{pool: pool, pool_ref: pool_ref}
          {{:ok, :ok}, %{state | transaction: transaction}}

        {:error, err} ->
          {{:error, {:checkout_failed, err}}, state}
      end
    end

    defp execute(%State{transaction: %{}} = _state, %Internal.BeginTransaction{}) do
      raise RuntimeError, "Nested transactions are not supported"
    end

    defp execute(
           %State{transaction: %{pool: pool, pool_ref: pool_ref}, repo: repo} = state,
           %Internal.CommitTransaction{}
         ) do
      # Execute COMMIT
      Ecto.Adapters.SQL.query!(repo, "COMMIT", [])

      # Remove from process dictionary
      Process.delete({Ecto.Adapters.SQL, pool})

      # Check connection back into pool
      DBConnection.Holder.checkin(pool_ref)

      # Clear transaction state
      {{:ok, :ok}, %{state | transaction: nil}}
    end

    defp execute(%State{transaction: nil} = _state, %Internal.CommitTransaction{}) do
      raise RuntimeError, "CommitTransaction called outside of transaction"
    end

    defp execute(
           %State{transaction: %{pool: pool, pool_ref: pool_ref}, repo: repo} = state,
           %Internal.RollbackTransaction{}
         ) do
      # Execute ROLLBACK
      Ecto.Adapters.SQL.query!(repo, "ROLLBACK", [])

      # Remove from process dictionary
      Process.delete({Ecto.Adapters.SQL, pool})

      # Check connection back into pool
      DBConnection.Holder.checkin(pool_ref)

      # Clear transaction state
      {{:ok, :ok}, %{state | transaction: nil}}
    end

    defp execute(%State{transaction: nil} = _state, %Internal.RollbackTransaction{}) do
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
    defp dispatch_query(registry, %Query{mod: mod} = query, _repo) when is_map(registry) do
      case Map.fetch(registry, mod) do
        {:ok, resolver} -> {:ok, invoke_query(resolver, query)}
        :error -> {:error, {:unknown_query_module, mod}}
      end
    end

    defp dispatch_query(resolver, query, _repo) do
      {:ok, invoke_query(resolver, query)}
    rescue
      exception -> {:error, {:query_failed, exception}}
    end

    defp invoke_query(:direct, %Query{mod: mod, name: name, params: params}) do
      apply(mod, name, [params])
    end

    defp invoke_query(fun, %Query{mod: mod, name: name, params: params})
         when is_function(fun, 3) do
      fun.(mod, name, params)
    end

    defp invoke_query({module, function}, %Query{mod: mod, name: name, params: params}) do
      apply(module, function, [mod, name, params])
    end

    defp invoke_query(module, %Query{mod: mod, name: name, params: params})
         when is_atom(module) do
      if function_exported?(module, :handle_query, 3) do
        apply(module, :handle_query, [mod, name, params])
      else
        raise ArgumentError,
              "#{inspect(module)} must export handle_query/3 to be used as a Query resolver"
      end
    end

    # ============================================================================
    # Algebra Implementation
    # ============================================================================

    @impl Freyja.Hefty.Algebra
    def handles?(sig) when sig == EctoFx, do: true
    def handles?(_), do: false

    @impl Freyja.Hefty.Algebra
    def elaborate(%Transaction{opts: opts}, psi, k, _elaborator) do
      inner = Map.fetch!(psi, :inner)

      use Freyja.Syntax

      con do
        _ <- Internal.begin_transaction(opts)

        # Interpose on Throw to rollback on error, and on Yield to error
        # (yielding inside a transaction would hold a DB connection indefinitely)
        guarded_inner =
          inner
          |> attach_rollback_on_throw()
          |> attach_error_on_yield()

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

    defp attach_error_on_yield(inner) do
      alias Freyja.Effects.Coroutine
      alias Freyja.Effects.Coroutine.Yield
      alias Freyja.Effects.Throw
      alias Freyja.Freer.Interpose

      use Freyja.Syntax

      Interpose.interpose_with(inner, Coroutine, fn %Yield{value: value}, _cont ->
        # Yield inside transaction: rollback first, then throw error
        # (we can't rely on attach_rollback_on_throw because this throw
        # is emitted inside the interpose handler, bypassing the outer interpose)
        con do
          _ <- Internal.rollback_transaction()
          Throw.throw_error({:yield_in_transaction, value})
        end
      end)
    end
  end
end
