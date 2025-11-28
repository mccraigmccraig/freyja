defmodule Freyja.Effects.Lift do
  @moduledoc """
  Lift first-order (Freer) effects into Hefty computations.

  The Lift effect bridges the gap between first-order algebraic effects
  (State, Error, Reader, etc.) and higher-order effects (Catch, Local, FxMap).

  ## Overview

  Lift is a higher-order effect that takes a Freer computation and embeds it
  in a Hefty computation. This allows mixing first-order and higher-order effects.

  ## Example

      import Freyja.Effects.Lift

      hefty do
        # Lift first-order State effect into Hefty
        x <- lift(State.get())

        # Use higher-order Catch effect
        y <- Catch.catch_hefty(
          lift(Error.throw_error("error")),
          Hefty.pure(0)
        )

        # Lift first-order State effect again
        lift(State.put(x + y))

        Hefty.pure(x + y)
      end

  ## Elaboration

  Lift elaborates trivially - it just unwraps the Freer computation and binds
  it with the continuation. Since the computation is already first-order, no
  transformation is needed.

  ## Note on Auto-Lifting

  In the future, the `hefty` macro will automatically detect Freer computations
  and lift them, making manual `lift/1` calls unnecessary in most cases.

  ## See Also

  - `Freyja.Effects.Lift.Algebra` - Trivial elaboration algebra
  - `Freyja.Freer` - First-order effect computations
  """

  @doc """
  The Lift operation struct.

  Fields:
  - computation: The Freer computation to lift into Hefty
  """
  defstruct [:computation]

  @type t :: %__MODULE__{
          computation: Freyja.Freer.t()
        }

  @doc """
  Lift a Freer computation into a Hefty computation.

  ## Parameters

  - `freer_comp` - A Freer.t() computation (first-order effects)

  ## Returns

  A Hefty.Impure node with the Lift operation (no forks needed).

  ## Example

      # Lift State.get into Hefty
      hefty_comp = lift(State.get())

      # Lift a complex Freer computation
      freer = con do
        x <- State.get()
        y <- Reader.ask()
        Freer.pure(x + y)
      end

      hefty_comp = lift(freer)
  """
  @spec lift(Freyja.Freer.t()) :: Freyja.Hefty.t()
  def lift(%Freyja.Freer.Pure{val: value}) do
    # Optimization: Pure values don't need Lift operation
    # Just convert directly to Hefty.Pure
    Freyja.Hefty.pure(value)
  end

  def lift(%Freyja.Freer.Impure{} = freer_comp) do
    # Freer.Impure (actual effects) need Lift operation
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %__MODULE__{computation: freer_comp},
      # No forks - the computation is data, not a parameter
      %{}
    )
  end
end

defmodule Freyja.Effects.Lift.Algebra do
  @moduledoc """
  Algebra for elaborating Lift operations.

  The Lift elaboration is trivial: just unwrap the Freer computation and bind
  it with the continuation.

  ## Strategy

  Since Lift embeds a Freer computation (which is already first-order), the
  elaboration just needs to:
  1. Extract the Freer computation from the operation
  2. Bind it with the elaborated continuation

  No transformation is needed - the computation is already in the target form.

  ## Example

  Input Hefty:
      Lift.lift(State.get())

  Elaborated Freer:
      Freer.bind(State.get(), k)

  The State.get() computation passes through unchanged.
  """

  @behaviour Freyja.Hefty.Algebra

  alias Freyja.Effects.Lift
  alias Freyja.Freer

  @impl true
  def handles_hefty?(sig) when sig == Freyja.Effects.Lift, do: true
  def handles_hefty?(_), do: false

  @impl true
  def elaborate(%Lift{computation: freer_comp}, _psi, k, _elaborator) do
    # Simple: bind the Freer computation with the continuation
    # The computation is already first-order, no transformation needed
    Freer.bind(freer_comp, k)
  end

  @doc """
  Add this algebra to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      hefty_computation |> Lift.Algebra.run()

      # Add to existing pipeline
      builder |> Lift.Algebra.run()
  """
  def run(computation_or_builder) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, nil)
  end
end
