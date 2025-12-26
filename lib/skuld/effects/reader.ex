defmodule Skuld.Effects.Reader do
  @moduledoc """
  Reader effect - access an immutable environment value.

  Demonstrates basic evidence-passing with `local` for scoped modification.
  """

  alias Skuld
  alias Skuld.Env

  @effect_key __MODULE__

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Read the current environment value"
  @spec ask() :: Skuld.computation()
  def ask do
    Skuld.effect(@effect_key, :ask)
  end

  @doc "Read and apply a function to the environment value"
  @spec asks((term() -> term())) :: Skuld.computation()
  def asks(f) do
    Skuld.map(ask(), f)
  end

  @doc "Run a computation with a modified environment value"
  @spec local((term() -> term()), Skuld.computation()) :: Skuld.computation()
  def local(modify, comp) do
    Skuld.scoped(
      fn env ->
        current = Env.get_state(env, @effect_key)
        modified_env = Env.put_state(env, @effect_key, modify.(current))
        restore = fn e -> Env.put_state(e, @effect_key, current) end
        {modified_env, restore}
      end,
      comp
    )
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc "Install the Reader handler with an initial value"
  @spec handler(Skuld.env(), term()) :: Skuld.env()
  def handler(env, value) do
    env
    |> Env.put_state(@effect_key, value)
    |> Env.with_handler(@effect_key, &handle/3)
  end

  # The handler implementation - returns {result, env} via k
  defp handle(:ask, env, k) do
    value = Env.get_state(env, @effect_key)
    k.(value, env)
  end
end
