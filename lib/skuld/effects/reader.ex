defmodule Skuld.Effects.Reader do
  @moduledoc """
  Reader effect - access an immutable environment value.

  Demonstrates basic evidence-passing with `local` for scoped modification.
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Env

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Ask)

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Read the current environment value"
  @spec ask() :: Comp.computation()
  def ask do
    Comp.effect(@sig, %Ask{})
  end

  @doc "Read and apply a function to the environment value"
  @spec asks((term() -> term())) :: Comp.computation()
  def asks(f) do
    Comp.map(ask(), f)
  end

  @doc "Run a computation with a modified environment value"
  @spec local((term() -> term()), Comp.computation()) :: Comp.computation()
  def local(modify, comp) do
    Comp.scoped(
      fn env ->
        current = Env.get_state(env, @sig)
        modified_env = Env.put_state(env, @sig, modify.(current))
        restore = fn e -> Env.put_state(e, @sig, current) end
        {modified_env, restore}
      end,
      comp
    )
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc "Install the Reader handler with an initial value"
  @spec handler(Comp.env(), term()) :: Comp.env()
  def handler(env, value) do
    env
    |> Env.put_state(@sig, value)
    |> Env.with_handler(@sig, &__MODULE__.handle/3)
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(%Ask{}, env, k) do
    value = Env.get_state(env, @sig)
    k.(value, env)
  end
end
