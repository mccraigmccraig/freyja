defmodule Skuld.Effects.Reader do
  @moduledoc """
  Reader effect - access an immutable environment value.

  Demonstrates basic evidence-passing with `local` for scoped modification.
  """

  alias Skuld
  alias Skuld.Env

  @effect_key :reader

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
    fn env, resume ->
      # Get current value, compute modified value
      current = Env.get_state(env, @effect_key)
      modified = modify.(current)

      # Run sub-computation with modified state
      modified_env = Env.put_state(env, @effect_key, modified)

      case comp.(modified_env, fn v, e -> {:done, v, e} end) do
        {:done, value, inner_env} ->
          # Restore original value after sub-computation
          restored_env = Env.put_state(inner_env, @effect_key, current)
          resume.(value, restored_env)

        # Pass through control effects (they carry their own env)
        other ->
          other
      end
    end
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

  # The handler implementation
  defp handle(:ask, env, resume) do
    value = Env.get_state(env, @effect_key)
    resume.(value, env)
  end
end
