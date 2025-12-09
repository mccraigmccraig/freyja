defmodule Skuld.Effects.State do
  @moduledoc """
  State effect - mutable state threaded through computation.

  Demonstrates state management in evidence-passing.
  """

  alias Skuld
  alias Skuld.Env

  @effect_key :state

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Get the current state"
  @spec get() :: Skuld.computation()
  def get do
    Skuld.effect(@effect_key, :get)
  end

  @doc "Replace the state, returning the old value"
  @spec put(term()) :: Skuld.computation()
  def put(value) do
    Skuld.effect(@effect_key, {:put, value})
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
    |> Env.put_state(@effect_key, initial)
    |> Env.with_handler(@effect_key, &handle/3)
  end

  @doc "Extract the final state from an env"
  @spec get_state(Skuld.env()) :: term()
  def get_state(env) do
    Env.get_state(env, @effect_key)
  end

  # Handler implementation
  defp handle(:get, env, resume) do
    value = Env.get_state(env, @effect_key)
    resume.(value, env)
  end

  defp handle({:put, value}, env, resume) do
    new_env = Env.put_state(env, @effect_key, value)
    resume.(:ok, new_env)
  end
end
