defmodule Skuld do
  @moduledoc """
  Skuld: Evidence-passing algebraic effects with final encoding.

  A minimal API sketch for validation.

  ## Core Concepts

  - **Computation**: `fn env, resume -> outcome` - a suspended computation
  - **Evidence**: Map of effect handlers in the environment
  - **Handler**: `fn args, env, resume -> outcome` - interprets an effect
  - **Outcome**: Tagged result - `:done`, `:suspended`, or `:thrown`

  ## Example

      import Skuld

      # Build a computation
      comp = bind(State.get(), fn x ->
        bind(State.put(x + 1), fn _ ->
          pure(x)
        end)
      end)

      # Run with handlers
      env = Env.new()
            |> State.handler(initial: 0)

      {:done, result, final_env} = run(comp, env)
  """

  #############################################################################
  ## Types
  #############################################################################

  @typedoc "The environment carrying evidence (handlers) and state"
  @type env :: %{
          evidence: %{atom() => handler()},
          state: %{atom() => term()}
        }

  @typedoc "A handler interprets effect operations"
  @type handler :: (args :: term(), env(), resume() -> outcome())

  @typedoc "Continuation to resume after an effect"
  @type resume :: (term(), env() -> outcome())

  @typedoc "A computation awaiting execution"
  @type computation :: (env(), resume() -> outcome())

  @typedoc "The result of running a computation"
  @type outcome ::
          {:done, term(), env()}
          | {:suspended, yielded :: term(), resume(), env()}
          | {:thrown, error :: term(), env()}

  #############################################################################
  ## Environment
  #############################################################################

  defmodule Env do
    @moduledoc "Environment construction and manipulation"

    @doc "Create a fresh environment"
    @spec new() :: Skuld.env()
    def new do
      %{evidence: %{}, state: %{}}
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

  @doc "Run a computation to completion or control effect"
  @spec run(computation(), env()) :: outcome()
  def run(comp, env) do
    comp.(env, fn value, final_env -> {:done, value, final_env} end)
  end

  @doc "Run a computation, extracting just the value (raises on non-done)"
  @spec run!(computation(), env()) :: term()
  def run!(comp, env) do
    case run(comp, env) do
      {:done, value, _env} -> value
      {:suspended, _, _, _} -> raise "Computation suspended unexpectedly"
      {:thrown, error, _} -> raise "Computation threw: #{inspect(error)}"
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
  ## Handler Scoping (for higher-order effects)
  #############################################################################

  @doc """
  Run a sub-computation with modified evidence.

  This is the key primitive for higher-order effects like Catch and Local.
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

  Useful for Listen, EffectLogger, etc.
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
