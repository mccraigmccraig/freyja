defmodule Freyja.Effects.Query do
  @moduledoc """
  Backend-agnostic data query effect.

  This effect lets domain code express “run this query” without binding to a
  particular storage layer. Each request specifies:

    * `domain` – logical backend identifier (e.g. `:postgres`, `:search`)
    * `mod` – module implementing the query
    * `name` – function name inside `mod`
    * `params` – map/struct of query parameters

  Handlers decide how to dispatch each request. The default runtime handler
  accepts a registry map keyed by domain so applications can plug in their own
  routing logic, while `TestHandler` makes it easy to stub responses in tests.
  """
  import Freyja.Freer.Sig.DefEffectStruct
  alias Freyja.Freer

  def_effect_struct(Request, domain: nil, mod: nil, name: nil, params: %{})

  @typedoc "Logical backend identifier (application-defined)"
  @type domain :: atom()

  @typedoc "Query module implementing `name/1`"
  @type query_module :: module()

  @typedoc "Function exported by `query_module`"
  @type query_name :: atom()

  @typedoc "Opaque parameter payload"
  @type params :: map() | struct()

  @doc """
  Build a query request for the given domain/module/function.
  """
  @spec request(domain(), query_module(), query_name(), params()) :: Freyja.Freer.t()
  def request(domain, mod, name, params \\ %{}) do
    %Request{domain: domain, mod: mod, name: name, params: params}
    |> Freer.send_effect()
  end

  @doc """
  Build a canonical key usable with `Query.TestHandler`.

  Parameters are normalized so that structurally-equal maps/structs produce the
  same key, independent of key ordering.
  """
  @spec key(domain(), query_module(), query_name(), params()) ::
          {domain(), query_module(), query_name(), binary()}
  def key(domain, mod, name, params) do
    {domain, mod, name, normalize_params(params)}
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
end

defmodule Freyja.Effects.Query.Handler do
  @moduledoc """
  Runtime handler for `Freyja.Effects.Query`.

  Provide a registry map keyed by `domain` when starting the handler. Each entry
  can be one of:

    * `:direct` – blindly call `apply(mod, name, [params])`
    * `function` (arity 4) – `fun.(domain, mod, name, params)`
    * `{module, function}` – invokes `apply(module, function, [domain, mod, name, params])`
    * `module` – invokes `module.handle_query(domain, mod, name, params)`

  Handlers may return any value. To signal errors, raise or emit
  `Freyja.Effects.Throw.throw_error/1`.
  """
  alias Freyja.Effects.Query
  alias Freyja.Effects.Query.Request
  alias Freyja.Effects.Throw
  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  @impl Freyja.Freer.EffectHandler
  def handles?(%Impure{sig: sig}, _state), do: sig == Query

  @impl Freyja.Freer.EffectHandler
  def interpret(
        %Freer.Impure{data: %Request{} = request, q: q},
        _handler_key,
        registry,
        %RunState{} = _run_state
      ) do
    case dispatch(registry, request) do
      {:ok, result} ->
        {Impl.q_apply(q, result), registry}

      {:error, reason} ->
        propagate_error(q, reason, registry)
    end
  end

  defp dispatch(registry, %Request{domain: domain} = request) when is_map(registry) do
    case Map.fetch(registry, domain) do
      {:ok, resolver} -> {:ok, invoke(resolver, request)}
      :error -> {:error, {:unknown_domain, domain}}
    end
  end

  defp dispatch(resolver, %Request{} = request) do
    {:ok, invoke(resolver, request)}
  rescue
    exception ->
      {:error, {:query_failed, exception}}
  end

  defp invoke(:direct, %Request{mod: mod, name: name, params: params}) do
    apply(mod, name, [params])
  end

  defp invoke(fun, %Request{domain: domain, mod: mod, name: name, params: params})
       when is_function(fun, 4) do
    fun.(domain, mod, name, params)
  end

  defp invoke({module, function}, %Request{domain: domain, mod: mod, name: name, params: params}) do
    apply(module, function, [domain, mod, name, params])
  end

  defp invoke(module, %Request{domain: domain, mod: mod, name: name, params: params})
       when is_atom(module) do
    if function_exported?(module, :handle_query, 4) do
      apply(module, :handle_query, [domain, mod, name, params])
    else
      raise ArgumentError,
            "#{inspect(module)} must export handle_query/4 to be used as a Query handler entry"
    end
  end

  defp propagate_error(q, reason, registry) do
    error_effect = Throw.throw_error(reason)
    {Impl.bindp(error_effect, q), registry}
  end

  @doc """
  Attach this handler to a computation or builder.

  Pass a domain registry map to control how queries are dispatched. Defaults to
  an empty registry, which will cause unknown-domain errors until populated.
  """
  @spec run(any, map()) :: any
  def run(computation_or_builder, registry \\ %{}) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, registry)
  end
end

defmodule Freyja.Effects.Query.TestHandler do
  @moduledoc """
  Canned-response handler for `Freyja.Effects.Query`.

  Provide a map of responses keyed by `Freyja.Effects.Query.key/4`. Example:

      responses = %{
        Query.key(:search, MyApp.SearchQueries, :find, %{term: \"foo\"}) => [%{id: 1}]
      }

      computation
      |> Query.TestHandler.run(responses)
      |> Run.run()

  Missing keys raise via `Throw.throw_error({:query_not_stubbed, key})`.
  """
  alias Freyja.Effects.Query
  alias Freyja.Effects.Query.Request
  alias Freyja.Effects.Throw
  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  @impl Freyja.Freer.EffectHandler
  def handles?(%Impure{sig: sig}, _state), do: sig == Query

  @impl Freyja.Freer.EffectHandler
  def interpret(
        %Freer.Impure{data: %Request{} = request, q: q},
        _handler_key,
        responses,
        %RunState{} = _run_state
      ) do
    key = Query.key(request.domain, request.mod, request.name, request.params)

    case Map.fetch(responses, key) do
      {:ok, result} ->
        {Impl.q_apply(q, result), responses}

      :error ->
        error = Throw.throw_error({:query_not_stubbed, key})
        {Impl.bindp(error, q), responses}
    end
  end

  @doc """
  Attach the canned-response handler to a computation or builder.
  """
  def run(computation_or_builder, responses) when is_map(responses) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, responses)
  end
end
