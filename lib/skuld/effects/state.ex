defmodule Skuld.Effects.State do
  @moduledoc """
  State effect - mutable state threaded through computation.

  Demonstrates state management in evidence-passing.
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Get)
  def_op(Put, [:value])

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Get the current state"
  @spec get() :: Types.computation()
  def get do
    Comp.effect(@sig, %Get{})
  end

  @doc "Replace the state, returning :ok"
  @spec put(term()) :: Types.computation()
  def put(value) do
    Comp.effect(@sig, %Put{value: value})
  end

  @doc "Modify the state with a function, returning the old value"
  @spec modify((term() -> term())) :: Types.computation()
  def modify(f) do
    Comp.bind(get(), fn old ->
      Comp.bind(put(f.(old)), fn _ ->
        Comp.pure(old)
      end)
    end)
  end

  @doc "Get a value derived from the state"
  @spec gets((term() -> term())) :: Types.computation()
  def gets(f) do
    Comp.map(get(), f)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped State handler for a computation.

  Installs the State handler and initializes state for the duration of `comp`.
  Both the handler and state are restored/removed when `comp` completes or throws.

  The argument order is pipe-friendly.

  ## Example

      # Wrap a computation with its own State
      comp_with_state =
        comp do
          x <- State.get()
          _ <- State.put(x + 1)
          return(x)
        end
        |> State.with_handler(0)

      # Can be nested - inner State shadows outer
      outer_comp = comp do
        _ <- State.put(100)
        inner_result <- State.get() |> State.with_handler(0)
        outer_val <- State.get()
        return({inner_result, outer_val})  # {0, 100}
      end

      # Compose multiple handlers with pipes
      my_comp
      |> Reader.with_handler(:config)
      |> State.with_handler(0)
      |> Comp.run(Env.new())
  """
  @spec with_handler(Types.computation(), term()) :: Types.computation()
  def with_handler(comp, initial) do
    comp
    |> Comp.scoped(fn env ->
      previous = Env.get_state(env, @sig)
      modified = Env.put_state(env, @sig, initial)

      finally_k = fn value, e ->
        restored_env =
          case previous do
            nil -> %{e | state: Map.delete(e.state, @sig)}
            val -> Env.put_state(e, @sig, val)
          end

        {value, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  @doc "Extract the final state from an env"
  @spec get_state(Types.env()) :: term()
  def get_state(env) do
    Env.get_state(env, @sig)
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(%Get{}, env, k) do
    value = Env.get_state(env, @sig)
    k.(value, env)
  end

  @impl Skuld.Comp.IHandler
  def handle(%Put{value: value}, env, k) do
    new_env = Env.put_state(env, @sig, value)
    k.(:ok, new_env)
  end
end
