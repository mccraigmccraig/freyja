defmodule Skuld do
  @moduledoc """
  Skuld: Evidence-passing algebraic effects with scoped handlers.

  ## Core Concepts

  - **Computation**: `(env, k -> {result, env})` - a suspended computation
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
  @type handler :: (args :: term(), env(), k() -> {result(), env()})

  @typedoc "Continuation after an effect"
  @type k :: (term(), env() -> {result(), env()})

  @typedoc "A computation awaiting execution"
  @type computation :: (env(), k() -> {result(), env()})

  @typedoc "Leave-scope handler - cleans up or redirects"
  @type leave_scope :: (result(), env() -> {result(), env()})

  # Env module is in lib/skuld/env.ex
  alias Skuld.Env

  #############################################################################
  ## Core Operations
  #############################################################################

  @doc "Lift a pure value into a computation"
  @spec pure(term()) :: computation()
  def pure(value) do
    fn env, k -> k.(value, env) end
  end

  @doc "Sequence computations"
  @spec bind(computation(), (term() -> computation())) :: computation()
  def bind(comp, f) do
    fn env, k ->
      comp.(env, fn a, env2 -> f.(a).(env2, k) end)
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
    fn env, k ->
      handler = Env.get_handler!(env, effect_key)
      handler.(args, env, k)
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
  Create a scoped computation with dual-path cleanup.

  The `setup` function receives the current env and must return
  `{modified_env, restore}` where `restore :: (env -> env)` restores
  the env to its pre-scope state.

  The restore function is called on both:
  - **Normal exit**: before continuing to outer computation
  - **Abnormal exit**: during leave-scope unwinding (e.g., throw)

  The previous leave-scope is automatically restored in both paths.

  ## Example

      def local(modify, comp) do
        Skuld.scoped(fn env ->
          current = Env.get_state(env, @effect_key)
          modified_env = Env.put_state(env, @effect_key, modify.(current))
          restore = fn e -> Env.put_state(e, @effect_key, current) end
          {modified_env, restore}
        end, comp)
      end
  """
  @spec scoped((env() -> {env(), (env() -> env())}), computation()) :: computation()
  def scoped(setup, comp) do
    fn env, outer_k ->
      previous_leave_scope = Env.get_leave_scope(env)
      {modified_env, restore} = setup.(env)

      # Normal exit: restore env and leave_scope before continuing
      restoring_k = fn value, inner_env ->
        restored_env =
          inner_env
          |> restore.()
          |> Env.with_leave_scope(previous_leave_scope)

        outer_k.(value, restored_env)
      end

      # Abnormal exit: restore env and leave_scope during unwinding
      my_leave_scope = fn result, inner_env ->
        cleaned_env =
          inner_env
          |> restore.()
          |> Env.with_leave_scope(previous_leave_scope)

        previous_leave_scope.(result, cleaned_env)
      end

      final_env = Env.with_leave_scope(modified_env, my_leave_scope)
      comp.(final_env, restoring_k)
    end
  end
end
