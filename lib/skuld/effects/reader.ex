defmodule Skuld.Effects.Reader do
  @moduledoc """
  Reader effect - access an immutable environment value.

  Demonstrates basic evidence-passing with `local` for scoped modification.
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Ask)

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Read the current environment value"
  @spec ask() :: Types.computation()
  def ask do
    Comp.effect(@sig, %Ask{})
  end

  @doc "Read and apply a function to the environment value"
  @spec asks((term() -> term())) :: Types.computation()
  def asks(f) do
    Comp.map(ask(), f)
  end

  @doc "Run a computation with a modified environment value"
  @spec local((term() -> term()), Types.computation()) :: Types.computation()
  def local(modify, comp) do
    Comp.scoped(comp, fn env ->
      current = Env.get_state(env, @sig)
      modified_env = Env.put_state(env, @sig, modify.(current))
      finally_k = fn value, e -> {value, Env.put_state(e, @sig, current)} end
      {modified_env, finally_k}
    end)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped Reader handler for a computation.

  Installs the Reader handler and context for the duration of `comp`.
  Both the handler and context are restored/removed when `comp` completes or throws.

  The argument order is pipe-friendly.

  ## Example

      # Wrap a computation with its own Reader context
      comp_with_reader =
        comp do
          cfg <- Reader.ask()
          return(cfg.config)
        end
        |> Reader.with_handler(%{config: "value"})

      # Can be nested - inner Reader shadows outer
      outer_comp = comp do
        outer_cfg <- Reader.ask()
        inner_result <- Reader.ask() |> Reader.with_handler(%{inner: true})
        return({outer_cfg, inner_result})
      end

      # Compose multiple handlers with pipes
      my_comp
      |> Reader.with_handler(:config)
      |> State.with_handler(0)
      |> Comp.run(Env.new())
  """
  @spec with_handler(Types.computation(), term()) :: Types.computation()
  def with_handler(comp, value) do
    comp
    |> Comp.scoped(fn env ->
      previous = Env.get_state(env, @sig)
      modified = Env.put_state(env, @sig, value)

      finally_k = fn v, e ->
        restored_env =
          case previous do
            nil -> %{e | state: Map.delete(e.state, @sig)}
            val -> Env.put_state(e, @sig, val)
          end

        {v, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
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
