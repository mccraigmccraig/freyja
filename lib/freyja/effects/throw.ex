defmodule Freyja.Effects.Throw do
  @moduledoc """
  First-order Throw effect for throwing errors.

  This module provides the `throw_error` operation (first-order).

  For the higher-order `catch` operation (catching and handling errors),
  use `Freyja.Effects.Catch` which provides Hefty algebra-based
  exception handling.

  ## Example

      import Freyja.Hefty.HeftyBlock

      # Throw an error
      Lift.lift(Throw.throw_error("something went wrong"))

  ## See Also

  - `Freyja.Effects.Catch` - For the higher-order catch operation
  """
  import Freyja.Freer.Sig.DefEffectStruct
  alias Freyja.Freer

  def_effect_struct(ThrowOp, error: nil)

  @doc """
  Throw an error, short-circuiting the computation.

  Returns a Freer effect that will fail with the given error value.
  """
  @spec throw_error(any) :: Freer.t()
  def throw_error(err), do: %ThrowOp{error: err} |> Freer.send_effect()
end

defmodule Freyja.Effects.Throw.Handler do
  @moduledoc """
  Handler for first-order Throw operations (throw only).

  This is a simple first-order effect handler. The scoped `catch` operation
  is available via `Freyja.Effects.Catch` as a Hefty algebra-based
  higher-order effect.

  ## Operations

  - `throw_error(error)` - Short-circuits computation with error

  ## See Also

  - `Freyja.Effects.Catch` - For the higher-order catch operation
  """

  alias Freyja.Freer
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Effects.Throw
  alias Freyja.Effects.Throw.ThrowOp

  @behaviour Freyja.Freer.EffectHandler

  # Internal marker struct to distinguish thrown errors from normal values
  # that happen to look like {:error, _} tuples
  defmodule ThrownError do
    @moduledoc false
    defstruct [:error]
  end

  @impl Freyja.Freer.EffectHandler
  def handles?(%Impure{sig: sig}, _state) do
    sig == Throw
  end

  @doc """
  Interpret a Throw operation.
  Wraps in ThrownError marker so finalize can distinguish from normal values.
  """
  @impl Freyja.Freer.EffectHandler
  def interpret(
        %Impure{sig: Throw, data: %ThrowOp{error: err}},
        _handler_key,
        _state,
        _run_state
      ) do
    # Throw short-circuits - discards queue
    # Wrap in ThrownError marker so finalize knows this came from throw
    {Freer.return(%ThrownError{error: err}), nil}
  end

  @doc """
  Wrap completed computations in {:ok, value} or {:error, reason}.

  Uses ThrownError marker to distinguish actual thrown errors from normal
  values that happen to look like {:error, _} tuples.
  """
  @impl Freyja.Freer.EffectHandler
  def finalize(%Pure{val: val}, _key, state, _run_state) do
    wrapped_val =
      case val do
        # Actual thrown error - unwrap marker and return as {:error, _}
        %ThrownError{error: err} -> {:error, err}
        # Normal value - wrap in {:ok, _}
        value -> {:ok, value}
      end

    {%Pure{val: wrapped_val}, state}
  end

  @doc """
  Add this handler to a computation or builder pipeline.

  ## Examples

      # Start new pipeline (stateless, typically uses nil)
      computation |> Throw.Handler.run()

      # Can provide explicit state if needed
      builder |> Throw.Handler.run(nil)
  """
  def run(computation_or_builder, initial_state \\ :__default__) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end
end
