defmodule Skuld do
  @moduledoc """
  Skuld: Evidence-passing algebraic effects with scoped handlers.

  ## Core Concepts

  - **Computation**: `(env, resume -> {result, env})` - a suspended computation
  - **Result**: Opaque value - framework doesn't impose shape
  - **Leave-scope**: Continuation chain for scope cleanup/control
  - **Suspend**: Sentinel struct that bypasses leave-scope

  ## Architecture

  Unlike Freyja's centralised interpreter, Skuld uses decentralised
  evidence-passing. Run acts as a **control authority** - it recognizes
  the Suspend sentinel and invokes the leave-scope chain - but treats
  results as opaque.

  Scoped effects (Reader.local, Catch) install leave-scope handlers
  that can clean up env or redirect control flow.
  """

  #############################################################################
  ## Structs
  #############################################################################

  defmodule Suspend do
    @moduledoc "Sentinel that bypasses leave-scope chain"
    defstruct [:value, :resume]
    # resume :: (input -> {result, env})
  end

  defmodule Throw do
    @moduledoc "Error result that Catch recognizes"
    defstruct [:error]
  end

  #############################################################################
  ## Types
  #############################################################################

  @typedoc "Any result value - opaque to the framework"
  @type result :: term()

  @typedoc "The environment carrying evidence, state, and leave-scope"
  @type env :: %{
          evidence: %{atom() => handler()},
          state: %{atom() => term()},
          leave_scope: leave_scope()
        }

  @typedoc "A handler interprets effect operations"
  @type handler :: (args :: term(), env(), resume() -> {result(), env()})

  @typedoc "Continuation to resume after an effect"
  @type resume :: (term(), env() -> {result(), env()})

  @typedoc "A computation awaiting execution"
  @type computation :: (env(), resume() -> {result(), env()})

  @typedoc "Leave-scope handler - cleans up or redirects"
  @type leave_scope :: (result(), env() -> {result(), env()})

  #############################################################################
  ## Environment
  #############################################################################

  defmodule Env do
    @moduledoc "Environment construction and manipulation"

    @doc "Create a fresh environment with identity leave-scope"
    @spec new() :: Skuld.env()
    def new do
      %{
        evidence: %{},
        state: %{},
        leave_scope: fn result, env -> {result, env} end
      }
    end

    @doc "Install a handler for an effect"
    @spec with_handler(Skuld.env(), atom(), Skuld.handler()) :: Skuld.env()
    def with_handler(env, effect_key, handler) do
      put_in(env, [:evidence, effect_key], handler)
    end

    @doc "Get handler for an effect (raises if missing)"
    @spec get_handler!(Skuld.env(), atom()) :: Skuld.handler()
    def get_handler!(env, effect_key) do
      case env.evidence[effect_key] do
        nil -> raise "No handler for effect: #{inspect(effect_key)}"
        handler -> handler
      end
    end

    @doc "Get handler for an effect (returns nil if missing)"
    @spec get_handler(Skuld.env(), atom()) :: Skuld.handler() | nil
    def get_handler(env, effect_key) do
      env.evidence[effect_key]
    end

    @doc "Update state for an effect"
    @spec put_state(Skuld.env(), atom(), term()) :: Skuld.env()
    def put_state(env, key, value) do
      put_in(env, [:state, key], value)
    end

    @doc "Get state for an effect"
    @spec get_state(Skuld.env(), atom(), term()) :: term()
    def get_state(env, key, default \\ nil) do
      Map.get(env.state, key, default)
    end

    @doc "Install a new leave-scope handler"
    @spec with_leave_scope(Skuld.env(), Skuld.leave_scope()) :: Skuld.env()
    def with_leave_scope(env, new_leave_scope) do
      %{env | leave_scope: new_leave_scope}
    end

    @doc "Get the current leave-scope handler"
    @spec get_leave_scope(Skuld.env()) :: Skuld.leave_scope()
    def get_leave_scope(env) do
      env.leave_scope
    end
  end

  #############################################################################
  ## Core Operations
  #############################################################################

  @doc "Lift a pure value into a computation"
  @spec pure(term()) :: computation()
  def pure(value) do
    fn env, resume -> resume.(value, env) end
  end

  @doc "Sequence computations"
  @spec bind(computation(), (term() -> computation())) :: computation()
  def bind(comp, f) do
    fn env, resume ->
      comp.(env, fn a, env2 -> f.(a).(env2, resume) end)
    end
  end

  @doc """
  Run a computation to completion.

  Checks for Suspend sentinel (bypasses leave-scope) and invokes
  the leave-scope chain for all other results.
  """
  @spec run(computation(), env()) :: {result(), env()}
  def run(comp, env) do
    env_with_leave_scope = Map.put_new(env, :leave_scope, fn r, e -> {r, e} end)

    {result, final_env} =
      comp.(env_with_leave_scope, fn value, e ->
        {value, e}
      end)

    case result do
      %Suspend{} = s -> {s, final_env}
      _ -> final_env.leave_scope.(result, final_env)
    end
  end

  @doc "Run a computation, extracting just the value (raises on Suspend/Throw)"
  @spec run!(computation(), env()) :: term()
  def run!(comp, env) do
    case run(comp, env) do
      {%Suspend{}, _} -> raise "Computation suspended unexpectedly"
      {%Throw{error: error}, _} -> raise "Computation threw: #{inspect(error)}"
      {value, _env} -> value
    end
  end

  #############################################################################
  ## Effect Invocation
  #############################################################################

  @doc "Invoke an effect operation"
  @spec effect(atom(), term()) :: computation()
  def effect(effect_key, args \\ nil) do
    fn env, resume ->
      handler = Env.get_handler!(env, effect_key)
      handler.(args, env, resume)
    end
  end

  #############################################################################
  ## Combinators
  #############################################################################

  @doc "Sequence computations, ignoring first result"
  @spec then_do(computation(), computation()) :: computation()
  def then_do(comp1, comp2) do
    bind(comp1, fn _ -> comp2 end)
  end

  @doc "Map over a computation's result"
  @spec map(computation(), (term() -> term())) :: computation()
  def map(comp, f) do
    bind(comp, fn a -> pure(f.(a)) end)
  end

  @doc "Flatten nested computations"
  @spec flatten(computation()) :: computation()
  def flatten(comp) do
    bind(comp, fn inner -> inner end)
  end

  @doc "Sequence a list of computations"
  @spec sequence([computation()]) :: computation()
  def sequence([]), do: pure([])

  def sequence([comp | rest]) do
    bind(comp, fn a ->
      bind(sequence(rest), fn as ->
        pure([a | as])
      end)
    end)
  end

  @doc "Apply f to each element, sequence the resulting computations"
  @spec traverse(list(), (term() -> computation())) :: computation()
  def traverse(list, f) do
    sequence(Enum.map(list, f))
  end

  #############################################################################
  ## Scoping Primitives
  #############################################################################

  @doc """
  Create a scoped computation with leave-scope cleanup.

  The `setup` function receives the current env and must return
  `{modified_env, cleanup}` where cleanup is `(result, env) -> {result, env}`.

  The cleanup function is automatically chained with the previous leave-scope.
  """
  @spec scoped((env() -> {env(), leave_scope()}), computation()) :: computation()
  def scoped(setup, comp) do
    fn env, resume ->
      previous_leave_scope = Env.get_leave_scope(env)
      {modified_env, cleanup} = setup.(env)

      my_leave_scope = fn result, inner_env ->
        {cleaned_result, cleaned_env} = cleanup.(result, inner_env)
        previous_leave_scope.(cleaned_result, cleaned_env)
      end

      final_env = Env.with_leave_scope(modified_env, my_leave_scope)
      comp.(final_env, resume)
    end
  end

  @doc """
  Run a sub-computation with modified evidence.

  Note: For scoped modifications that need cleanup, use `scoped/2` instead.
  """
  @spec with_evidence(computation(), (env() -> env())) :: computation()
  def with_evidence(comp, modify_env) do
    fn env, resume ->
      modified_env = modify_env.(env)
      comp.(modified_env, resume)
    end
  end

  @doc """
  Interpose on an existing handler - wrap it with additional behavior.
  """
  @spec interpose(computation(), atom(), (handler() -> handler())) :: computation()
  def interpose(comp, effect_key, wrapper) do
    with_evidence(comp, fn env ->
      original = Env.get_handler!(env, effect_key)
      wrapped = wrapper.(original)
      Env.with_handler(env, effect_key, wrapped)
    end)
  end
end
