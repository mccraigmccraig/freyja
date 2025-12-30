defmodule Skuld.Effects.State do
  @moduledoc """
  State effect - mutable state threaded through computation.

  Demonstrates state management in evidence-passing.
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Env

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
  @spec get() :: Comp.computation()
  def get do
    Comp.effect(@sig, %Get{})
  end

  @doc "Replace the state, returning :ok"
  @spec put(term()) :: Comp.computation()
  def put(value) do
    Comp.effect(@sig, %Put{value: value})
  end

  @doc "Modify the state with a function, returning the old value"
  @spec modify((term() -> term())) :: Comp.computation()
  def modify(f) do
    Comp.bind(get(), fn old ->
      Comp.bind(put(f.(old)), fn _ ->
        Comp.pure(old)
      end)
    end)
  end

  @doc "Get a value derived from the state"
  @spec gets((term() -> term())) :: Comp.computation()
  def gets(f) do
    Comp.map(get(), f)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc "Install the State handler with an initial value"
  @spec handler(Comp.env(), term()) :: Comp.env()
  def handler(env, initial) do
    env
    |> Env.put_state(@sig, initial)
    |> Env.with_handler(@sig, &__MODULE__.handle/3)
  end

  @doc "Extract the final state from an env"
  @spec get_state(Comp.env()) :: term()
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
