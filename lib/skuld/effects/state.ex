defmodule Skuld.Effects.State do
  @moduledoc """
  State effect - mutable state threaded through computation.

  Demonstrates state management in evidence-passing.
  """

  alias Skuld
  alias Skuld.Env

  @sig __MODULE__

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Get the current state"
  @spec get() :: Skuld.computation()
  def get do
    Skuld.effect(@sig, :get)
  end

  @doc "Replace the state, returning :ok"
  @spec put(term()) :: Skuld.computation()
  def put(value) do
    Skuld.effect(@sig, {:put, value})
  end

  @doc "Modify the state with a function, returning the old value"
  @spec modify((term() -> term())) :: Skuld.computation()
  def modify(f) do
    Skuld.bind(get(), fn old ->
      Skuld.bind(put(f.(old)), fn _ ->
        Skuld.pure(old)
      end)
    end)
  end

  @doc "Get a value derived from the state"
  @spec gets((term() -> term())) :: Skuld.computation()
  def gets(f) do
    Skuld.map(get(), f)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc "Install the State handler with an initial value"
  @spec handler(Skuld.env(), term()) :: Skuld.env()
  def handler(env, initial) do
    env
    |> Env.put_state(@sig, initial)
    |> Env.with_handler(@sig, &handle/3)
  end

  @doc "Extract the final state from an env"
  @spec get_state(Skuld.env()) :: term()
  def get_state(env) do
    Env.get_state(env, @sig)
  end

  # Handler implementation - returns {result, env} via k
  defp handle(:get, env, k) do
    value = Env.get_state(env, @sig)
    k.(value, env)
  end

  defp handle({:put, value}, env, k) do
    new_env = Env.put_state(env, @sig, value)
    k.(:ok, new_env)
  end
end
