defmodule Skuld.Comp.Env do
  @moduledoc """
  Environment construction and manipulation.

  The Env struct carries evidence (handlers), state, and the leave-scope chain.
  It supports extension fields - arbitrary atom keys can be added via `Map.put/3`.
  """

  @typedoc """
  The environment struct. Supports extension fields beyond the core struct keys
  (structs are maps, so `Map.put(env, :custom_key, value)` works).
  """
  @type t :: %__MODULE__{
          evidence: %{Skuld.Comp.Types.sig() => Skuld.Comp.Types.handler()},
          state: %{term() => term()},
          leave_scope: Skuld.Comp.Types.leave_scope() | nil
        }

  defstruct evidence: %{},
            state: %{},
            leave_scope: nil

  @doc "Create a fresh environment with identity leave-scope"
  @spec new() :: Skuld.Comp.Types.env()
  def new do
    %__MODULE__{
      leave_scope: fn result, env -> {result, env} end
    }
  end

  @doc "Install a handler for an effect signature"
  @spec with_handler(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig(), Skuld.Comp.Types.handler()) ::
          Skuld.Comp.Types.env()
  def with_handler(env, sig, handler) do
    %{env | evidence: Map.put(env.evidence, sig, handler)}
  end

  @doc "Get handler for an effect signature (raises if missing)"
  @spec get_handler!(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig()) :: Skuld.Comp.Types.handler()
  def get_handler!(env, sig) do
    case env.evidence[sig] do
      nil -> raise "No handler for effect signature: #{inspect(sig)}"
      handler -> handler
    end
  end

  @doc "Get handler for an effect signature (returns nil if missing)"
  @spec get_handler(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig()) ::
          Skuld.Comp.Types.handler() | nil
  def get_handler(env, sig) do
    env.evidence[sig]
  end

  @doc "Remove a handler for an effect signature"
  @spec delete_handler(Skuld.Comp.Types.env(), Skuld.Comp.Types.sig()) :: Skuld.Comp.Types.env()
  def delete_handler(env, sig) do
    %{env | evidence: Map.delete(env.evidence, sig)}
  end

  @doc "Update state for an effect"
  @spec put_state(Skuld.Comp.Types.env(), term(), term()) :: Skuld.Comp.Types.env()
  def put_state(env, key, value) do
    %{env | state: Map.put(env.state, key, value)}
  end

  @doc "Get state for an effect"
  @spec get_state(Skuld.Comp.Types.env(), term(), term()) :: term()
  def get_state(env, key, default \\ nil) do
    Map.get(env.state, key, default)
  end

  @doc "Install a new leave-scope handler"
  @spec with_leave_scope(Skuld.Comp.Types.env(), Skuld.Comp.Types.leave_scope()) ::
          Skuld.Comp.Types.env()
  def with_leave_scope(env, new_leave_scope) do
    %{env | leave_scope: new_leave_scope}
  end

  @doc "Get the current leave-scope handler"
  @spec get_leave_scope(Skuld.Comp.Types.env()) :: Skuld.Comp.Types.leave_scope()
  def get_leave_scope(env) do
    env.leave_scope
  end
end
