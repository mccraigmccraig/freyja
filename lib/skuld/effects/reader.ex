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
    fn env, outer_resume ->
      current = Env.get_state(env, @effect_key)
      modified_env = Env.put_state(env, @effect_key, modify.(current))

      # Wrap resume to restore env on normal completion
      restoring_resume = fn value, inner_env ->
        restored_env = Env.put_state(inner_env, @effect_key, current)
        outer_resume.(value, restored_env)
      end

      # Also install leave_scope for cleanup on abnormal exit (throw)
      previous_leave_scope = Env.get_leave_scope(modified_env)

      my_leave_scope = fn result, leave_env ->
        # Restore reader value and continue chain
        restored_env = Env.put_state(leave_env, @effect_key, current)
        previous_leave_scope.(result, restored_env)
      end

      final_env = Env.with_leave_scope(modified_env, my_leave_scope)
      comp.(final_env, restoring_resume)
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

  # The handler implementation - returns {result, env} via resume
  defp handle(:ask, env, resume) do
    value = Env.get_state(env, @effect_key)
    resume.(value, env)
  end
end
