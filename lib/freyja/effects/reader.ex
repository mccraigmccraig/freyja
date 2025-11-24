defmodule Freyja.Effects.Reader do
  @moduledoc """
  Operations for the Reader effect.

  ## First-Order Operations
  - `ask/0` - Read the current environment

  ## Higher-Order Operations
  - `local/2` - Temporarily modify the environment for a scoped computation
  """
  import Freyja.Freer.Sig.DefEffectStruct
  import Freyja.Hefty.Sig.DefHeftyStruct
  alias Freyja.Freer

  # First-order operation
  def_effect_struct(Ask)

  @spec ask :: Freer.t()
  def ask, do: %Ask{} |> Freer.send_effect()

  # Higher-order operation
  def_hefty_struct(Local, modifier_fn: nil)

  @doc """
  Run a computation with a temporarily modified environment.

  The modifier function receives the current environment and returns a modified version.
  This modified environment is used for all `ask/0` calls within the inner computation.
  After the inner computation completes, the original environment is restored.

  ## Parameters
  - `modifier_fn` - Function `(env -> env)` that transforms the environment
  - `inner_comp` - Hefty computation to run with the modified environment

  ## Example

      hefty do
        base_config <- Reader.ask()

        result <- Reader.local(
          fn config -> %{config | debug: true} end,
          hefty do
            cfg <- Lift.lift(Reader.ask())
            Hefty.pure(cfg.debug)  # => true
          end
        )

        final_config <- Reader.ask()
        Hefty.pure({result, final_config.debug})  # => {true, false}
      end
  """
  def local(modifier_fn, inner_comp) when is_function(modifier_fn, 1) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %Local{modifier_fn: modifier_fn},
      %{inner: inner_comp}
    )
  end
end

defmodule Freyja.Effects.Reader.Algebra do
  @moduledoc """
  Algebra for elaborating Reader.Local operations.

  ## Overview

  The Local operation provides scoped modification of the Reader environment.
  It intercepts `Reader.Ask` operations within a computation and provides them
  with a modified environment, without affecting Reader operations outside the scope.

  ## Elaboration Strategy

  Uses interposition to structurally transform the inner computation:

  1. Intercept all `Reader.Ask` operations in the inner computation
  2. For each intercepted Ask, apply the modifier function to the environment
  3. Pass the modified environment to the continuation
  4. The original environment is automatically restored outside the scope

  ## State Propagation

  State propagates naturally through interposition - no special handling needed.
  All effects at the same level, no nested interpretation.

  ## Suspensions

  Suspensions (like Coroutine.yield) work automatically because the interposition
  is baked into the computation structure. When resuming, the modified environment
  context is preserved.
  """

  @behaviour Freyja.Hefty.Algebra

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.Reader
  alias Freyja.Effects.Reader.Local
  alias Freyja.Freer
  alias Freyja.Freer.Interpose

  @impl true
  def handles?(sig) when sig == Reader, do: true
  def handles?(_), do: false

  @impl true
  def elaborate(%Local{modifier_fn: modifier_fn} = _op, psi, k, _elaborator) do
    # Extract the already-elaborated inner computation (Freer)
    inner_comp = Map.fetch!(psi, :inner)

    # Interpose on Reader.Ask operations to modify the returned environment
    transformed =
      Interpose.interpose_with(
        inner_comp,
        # Match only Reader.Ask operations
        fn sig, data ->
          sig == Reader and match?(%Reader.Ask{}, data)
        end,
        # When we intercept an Ask, get the environment and modify it
        fn %Reader.Ask{}, continuation ->
          con do
            env <- Reader.ask()
            modified_env = modifier_fn.(env)
            continuation.(modified_env)
          end
        end
      )

    # Bind the transformed computation to the outer continuation
    Freer.bind(transformed, k)
  end

  @doc """
  Add this algebra to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      hefty_computation |> Reader.Algebra.run()

      # Add to existing pipeline
      builder |> Reader.Algebra.run()
  """
  def run(computation_or_builder) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, nil)
  end
end

defmodule Freyja.Effects.Reader.Handler do
  @moduledoc "Interpreter (handler) for the Reader effect"
  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Effects.Reader
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  @impl Freyja.Freer.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == Reader
  end

  @impl Freyja.Freer.EffectHandler
  def interpret(
        %Freer.Impure{sig: Reader, data: u, q: q} = _computation,
        _handler_key,
        state,
        %RunState{} = _run_state
      ) do
    case u do
      %Reader.Ask{} ->
        {Impl.q_apply(q, state), state}
    end
  end

  @doc """
  Add this handler to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      computation |> Reader.Handler.run(env)

      # Add to existing pipeline
      builder |> Reader.Handler.run(%{config: value})
  """
  def run(computation_or_builder, initial_state) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end
end
