defmodule Skuld.Comp do
  @moduledoc """
  Skuld.Comp: Evidence-passing algebraic effects with scoped handlers.

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

  defmodule InvalidComputation do
    @moduledoc """
    Raised when a non-computation value is used where a computation is expected.

    This typically indicates a programming bug such as forgetting `return(value)`
    at the end of a comp block.
    """
    defexception [:message, :value]
  end

  # Sentinel protocol and types are in their own files:
  # - Skuld.Comp.Types (type definitions)
  # - Skuld.Comp.ISentinel (protocol)
  # - Skuld.Comp.Suspend (bypasses leave-scope)
  # - Skuld.Comp.Throw (error sentinel)
  alias Skuld.Comp.Env
  alias Skuld.Comp.ISentinel
  alias Skuld.Comp.Types

  #############################################################################
  ## Core Operations
  #############################################################################

  @doc "Lift a pure value into a computation"
  @spec pure(term()) :: Types.computation()
  def pure(value) do
    fn env, k -> k.(value, env) end
  end

  @doc """
  Call a computation with validation and exception handling.

  Raises a helpful error if the value is not a valid computation (2-arity function).
  This catches common mistakes like forgetting `return(value)` at the end of a comp block.

  Elixir exceptions (raise/throw/exit) are caught and converted to Throw effects,
  allowing them to be handled uniformly with effect-based errors via `catch_error`.

  Note: `InvalidComputation` errors (validation failures) are re-raised rather than
  converted to Throws, since they represent programming bugs that should fail fast.
  """
  @spec call(Types.computation(), Types.env(), Types.k()) :: {Types.result(), Types.env()}
  def call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    :error, %__MODULE__.InvalidComputation{} = e ->
      # Re-raise validation errors - these are programming bugs, not runtime errors
      reraise e, __STACKTRACE__

    kind, payload ->
      error = %{kind: kind, payload: payload, stacktrace: __STACKTRACE__}
      leave_scope = Map.get(env, :leave_scope, fn r, e -> {r, e} end)
      leave_scope.(%Skuld.Comp.Throw{error: error}, env)
  end

  def call(comp, _env, _k) do
    raise __MODULE__.InvalidComputation,
      value: comp,
      message: """
      Expected a computation, got: #{inspect(comp)}

      A computation must be a 2-arity function: fn env, k -> ... end

      Common causes:
      - Forgot `return(value)` at the end of a comp block
      - Used a non-computation value in a `<-` binding

      Example fix:
        comp do
          x <- State.get()
          return(x + 1)  # <-- wrap final value with return
        end
      """
  end

  @doc "Sequence computations"
  @spec bind(Types.computation(), (term() -> Types.computation())) :: Types.computation()
  def bind(comp, f) do
    fn env, k ->
      call(comp, env, fn a, env2 ->
        call(f.(a), env2, k)
      end)
    end
  end

  @doc "identity cntinuation - for initial continuation & default leave-scope"
  def identity_k(val, env), do: {val, env}

  @doc """
  Run a computation to completion.

  Creates a fresh environment internally - all handler installation should
  be done via `with_handler` on the computation.

  Uses ISentinel protocol to determine completion behavior:
  - Suspend: bypasses leave-scope chain
  - Other values: invoke leave-scope chain

  ## Example

      {result, _env} =
        my_comp
        |> State.with_handler(0)
        |> Reader.with_handler(:config)
        |> Comp.run()
  """
  @spec run(Types.computation()) :: {Types.result(), Types.env()}
  def run(comp) do
    {result, final_env} =
      call(
        comp,
        Env.with_leave_scope(Env.new(), &identity_k/2),
        &identity_k/2
      )

    ISentinel.run(result, final_env)
  end

  @doc "Run a computation, extracting just the value (raises on Suspend/Throw)"
  @spec run!(Types.computation()) :: term()
  def run!(comp) do
    {result, _env} = run(comp)
    ISentinel.run!(result)
  end

  #############################################################################
  ## Effect Invocation
  #############################################################################

  @doc """
  Call an effect handler with exception handling.

  Similar to `call/3` but for 3-arity handlers. Exceptions in handler code
  are caught and converted to Throw effects.
  """
  @spec call_handler(Types.handler(), term(), Types.env(), Types.k()) ::
          {Types.result(), Types.env()}
  def call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    :error, %__MODULE__.InvalidComputation{} = e ->
      reraise e, __STACKTRACE__

    kind, payload ->
      error = %{kind: kind, payload: payload, stacktrace: __STACKTRACE__}
      leave_scope = Map.get(env, :leave_scope, fn r, e -> {r, e} end)
      leave_scope.(%Skuld.Comp.Throw{error: error}, env)
  end

  @doc "Invoke an effect operation"
  @spec effect(Types.sig(), term()) :: Types.computation()
  def effect(sig, args \\ nil) do
    fn env, k ->
      handler = Env.get_handler!(env, sig)
      call_handler(handler, args, env, k)
    end
  end

  #############################################################################
  ## Combinators
  #############################################################################

  @doc "Sequence computations, ignoring first result"
  @spec then_do(Types.computation(), Types.computation()) :: Types.computation()
  def then_do(comp1, comp2) do
    bind(comp1, fn _ -> comp2 end)
  end

  @doc "Map over a computation's result"
  @spec map(Types.computation(), (term() -> term())) :: Types.computation()
  def map(comp, f) do
    bind(comp, fn a -> pure(f.(a)) end)
  end

  @doc "Flatten nested computations"
  @spec flatten(Types.computation()) :: Types.computation()
  def flatten(comp) do
    fn env, k ->
      call(comp, env, fn inner, env2 ->
        call(inner, env2, k)
      end)
    end
  end

  @doc "Sequence a list of computations"
  @spec sequence([Types.computation()]) :: Types.computation()
  def sequence([]), do: pure([])

  def sequence([comp | rest]) do
    bind(comp, fn a ->
      bind(sequence(rest), fn as ->
        pure([a | as])
      end)
    end)
  end

  @doc "Apply f to each element, sequence the resulting computations"
  @spec traverse(list(), (term() -> Types.computation())) :: Types.computation()
  def traverse(list, f) do
    sequence(Enum.map(list, f))
  end

  #############################################################################
  ## Scoping Primitives
  #############################################################################

  @doc """
  Create a scoped computation with a final continuation for cleanup and result transformation.

  The `setup` function receives the current env and must return
  `{modified_env, finally_k}` where `finally_k :: (value, env) -> {value, env}`
  is a continuation that runs when the scope exits.

  This enables Koka-style `with` semantics where handlers can transform
  computation results (e.g., wrapping with collected state, logs, etc.).

  The `finally_k` continuation is called on both:
  - **Normal exit**: before continuing to outer computation
  - **Abnormal exit**: during leave-scope unwinding (e.g., throw)

  The previous leave-scope is automatically restored in both paths.

  The argument order is pipe-friendly (computation first).

  ## Example - Environment restoration only

      def local(modify, comp) do
        comp
        |> Skuld.Comp.scoped(fn env ->
          current = Env.get_state(env, @sig)
          modified_env = Env.put_state(env, @sig, modify.(current))
          finally_k = fn value, e -> {value, Env.put_state(e, @sig, current)} end
          {modified_env, finally_k}
        end)
      end

  ## Example - Result transformation (like EffectLogger)

      def with_logging(comp) do
        comp
        |> Skuld.Comp.scoped(fn env ->
          env_with_log = Env.put_state(env, :log, [])

          finally_k = fn value, e ->
            log = Env.get_state(e, :log)
            cleaned = Map.delete(e.state, :log)
            {{value, Enum.reverse(log)}, %{e | state: cleaned}}
          end

          {env_with_log, finally_k}
        end)
      end
  """
  @spec scoped(Types.computation(), (Types.env() -> {Types.env(), Types.leave_scope()})) ::
          Types.computation()
  def scoped(comp, setup) do
    fn env, outer_k ->
      previous_leave_scope = Env.get_leave_scope(env)
      {modified_env, finally_k} = setup.(env)

      # Normal exit: run finally_k then continue to outer
      normal_k = fn value, inner_env ->
        {new_value, final_env} = finally_k.(value, inner_env)
        outer_k.(new_value, Env.with_leave_scope(final_env, previous_leave_scope))
      end

      # Abnormal exit: run finally_k during leave-scope unwinding
      my_leave_scope = fn result, inner_env ->
        {new_result, final_env} = finally_k.(result, inner_env)
        previous_leave_scope.(new_result, Env.with_leave_scope(final_env, previous_leave_scope))
      end

      call(comp, Env.with_leave_scope(modified_env, my_leave_scope), normal_k)
    end
  end

  @doc """
  Install a scoped handler for an effect.

  The handler is installed for the duration of `comp` and then restored
  to its previous state (or removed if there was no previous handler).

  This allows "shadowing" handlers - an inner computation can have its
  own handler for an effect while an outer handler exists.

  The argument order is pipe-friendly (computation first).

  ## Example

      # Create a computation with its own State handler
      inner =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          return(x)
        end
        |> Comp.with_handler(State, &State.handle/3)

      # Use it - inner State is independent of outer State
      outer = comp do
        _ <- State.put(100)
        result <- inner        # uses inner's handler
        y <- State.get()       # uses outer's handler, still 100
        return({result, y})
      end
  """
  @spec with_handler(Types.computation(), Types.sig(), Types.handler()) :: Types.computation()
  def with_handler(comp, sig, handler) do
    scoped(
      comp,
      fn env ->
        previous = Env.get_handler(env, sig)
        modified_env = Env.with_handler(env, sig, handler)

        finally_k = fn value, e ->
          restored_env =
            case previous do
              nil -> Env.delete_handler(e, sig)
              h -> Env.with_handler(e, sig, h)
            end

          {value, restored_env}
        end

        {modified_env, finally_k}
      end
    )
  end
end
