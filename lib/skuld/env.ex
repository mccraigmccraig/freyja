defmodule Skuld.Env do
  @moduledoc "Environment construction and manipulation"

  @doc "Create a fresh environment with identity leave-scope"
  @spec new() :: Skuld.env()
  def new do
    %{
      evidence: %{},
      state: %{},
      leave_scope: fn result, env -> {result, env} end
    }
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

  @doc "Get handler for an effect (returns nil if missing)"
  @spec get_handler(Skuld.env(), atom()) :: Skuld.handler() | nil
  def get_handler(env, effect_key) do
    env.evidence[effect_key]
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

  @doc "Install a new leave-scope handler"
  @spec with_leave_scope(Skuld.env(), Skuld.leave_scope()) :: Skuld.env()
  def with_leave_scope(env, new_leave_scope) do
    %{env | leave_scope: new_leave_scope}
  end

  @doc "Get the current leave-scope handler"
  @spec get_leave_scope(Skuld.env()) :: Skuld.leave_scope()
  def get_leave_scope(env) do
    env.leave_scope
  end
end
