if Code.ensure_loaded?(Ecto) do
  defmodule Freyja.Effects.EctoFx.TestHandler do
    @moduledoc """
    Test handler for `Freyja.Effects.EctoFx` that doesn't require a database.

    Useful for testing effectful code without database setup. Provides canned
    responses and tracks all operations for assertions.

    ## Usage

        # Create handler state with optional stubs
        state = EctoFx.TestHandler.new()
        |> EctoFx.TestHandler.stub_query(MyQueries, :find_user, %{id: 1}, {:ok, %User{id: 1}})
        |> EctoFx.TestHandler.stub_insert(User, fn changeset ->
          {:ok, %User{id: 1, name: Ecto.Changeset.get_field(changeset, :name)}}
        end)

        computation
        |> EctoFx.TestHandler.run(state)
        |> Run.run()

    ## Tracking Operations

    After running, you can inspect all operations that were attempted:

        outcome = Run.run(builder)
        state = outcome.outputs[EctoFx.TestHandler]
        ops = EctoFx.TestHandler.get_operations(state)
    """

    alias Freyja.Effects.EctoFx
    alias Freyja.Effects.EctoFx.Change
    alias Freyja.Effects.EctoFx.Delete
    alias Freyja.Effects.EctoFx.DeleteAll
    alias Freyja.Effects.EctoFx.Insert
    alias Freyja.Effects.EctoFx.InsertAll
    alias Freyja.Effects.EctoFx.InsertOrUpdate
    alias Freyja.Effects.EctoFx.Internal
    alias Freyja.Effects.EctoFx.Internal.BeginCapture
    alias Freyja.Effects.EctoFx.Internal.BeginTransaction
    alias Freyja.Effects.EctoFx.Internal.CommitTransaction
    alias Freyja.Effects.EctoFx.Internal.FinishCapture
    alias Freyja.Effects.EctoFx.Internal.RollbackTransaction
    alias Freyja.Effects.EctoFx.Query
    alias Freyja.Effects.EctoFx.Update
    alias Freyja.Effects.EctoFx.UpdateAll

    alias Freyja.Effects.EctoFx.Handler
    alias Freyja.Effects.Throw
    alias Freyja.Freer.Impl
    alias Freyja.Freer.Impure
    alias Freyja.Run.RunState

    @behaviour Freyja.Hefty.Algebra
    @behaviour Freyja.Freer.EffectHandler

    defmodule State do
      @moduledoc """
      Test handler state for tracking operations and providing stubs.
      """
      defstruct query_stubs: %{},
                mutation_stubs: %{},
                operations: [],
                capture: nil,
                next_capture_ref: 1,
                in_transaction: false

      @type t :: %__MODULE__{
              query_stubs: map(),
              mutation_stubs: map(),
              operations: list(),
              capture: map() | nil,
              next_capture_ref: non_neg_integer(),
              in_transaction: boolean()
            }
    end

    @doc "Create a new test handler state."
    def new, do: %State{}

    @doc "Stub a query response for specific params."
    def stub_query(%State{query_stubs: stubs} = state, mod, name, params, result) do
      key = EctoFx.query_key(mod, name, params)
      %{state | query_stubs: Map.put(stubs, key, result)}
    end

    @doc """
    Stub a query with a function that receives the params.

    Useful when you need dynamic responses based on query params.

    ## Example

        state =
          EctoFx.TestHandler.new()
          |> EctoFx.TestHandler.stub_query_fn(Queries, :find_user, fn %{id: id} ->
            %User{id: id, name: "User \#{id}"}
          end)
    """
    def stub_query_fn(%State{query_stubs: stubs} = state, mod, name, fun)
        when is_function(fun, 1) do
      key = {mod, name, :fn}
      %{state | query_stubs: Map.put(stubs, key, fun)}
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

    # Algebra implementation (delegates to Handler)
    @impl Freyja.Hefty.Algebra
    def handles_hefty?(sig) when sig == EctoFx, do: true
    def handles_hefty?(_), do: false

    @impl Freyja.Hefty.Algebra
    defdelegate elaborate(op, psi, k, elaborator), to: Handler

    # Handler implementation
    @impl Freyja.Freer.EffectHandler
    def handles?(%Impure{sig: sig}, _state), do: sig == EctoFx or sig == Internal

    @impl Freyja.Freer.EffectHandler
    def interpret(%Impure{sig: sig, data: op, q: q}, _handler_key, state, %RunState{})
        when sig == EctoFx or sig == Internal do
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
      key = EctoFx.query_key(mod, name, params)
      fn_key = {mod, name, :fn}

      case Map.fetch(stubs, key) do
        {:ok, result} ->
          # Exact params match
          {{:ok, result}, state}

        :error ->
          # Check for function-based stub
          case Map.fetch(stubs, fn_key) do
            {:ok, fun} when is_function(fun, 1) ->
              {{:ok, fun.(params)}, state}

            :error ->
              {{:error, {:query_not_stubbed, key}}, state}
          end
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
