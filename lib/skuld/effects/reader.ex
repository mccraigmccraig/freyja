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

  @doc """
  Install a scoped Reader handler for a computation.

  Installs the Reader handler and context for the duration of `comp`.
  Both the handler and context are restored/removed when `comp` completes or throws.

  This is the composable alternative to `handler/2` - it operates on computations
  rather than environments. The argument order is pipe-friendly.

  ## Example

      # Wrap a computation with its own Reader context
      comp_with_reader =
        comp do
          cfg <- Reader.ask()
          return(cfg.config)
        end
        |> Reader.with_scoped_handler(%{config: "value"})

      # Can be nested - inner Reader shadows outer
      outer_comp = comp do
        outer_cfg <- Reader.ask()
        inner_result <- Reader.ask() |> Reader.with_scoped_handler(%{inner: true})
        return({outer_cfg, inner_result})
      end

      # Compose multiple handlers with pipes
      my_comp
      |> Reader.with_scoped_handler(:config)
      |> State.with_scoped_handler(0)
      |> Comp.run(Env.new())
  """
  @spec with_scoped_handler(Comp.computation(), term()) :: Comp.computation()
  def with_scoped_handler(comp, value) do
    Comp.handle(
      @sig,
      &__MODULE__.handle/3,
      Comp.scoped(
        fn env ->
          previous = Env.get_state(env, @sig)
          modified = Env.put_state(env, @sig, value)

          restore = fn e ->
            case previous do
              nil -> %{e | state: Map.delete(e.state, @sig)}
              val -> Env.put_state(e, @sig, val)
            end
          end

          {modified, restore}
        end,
        comp
      )
    )
  end

  @doc "Install the Reader handler with an initial value (env-based, for top-level setup)"
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
