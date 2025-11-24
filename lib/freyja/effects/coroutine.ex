# Operations for the coroutine effect
defmodule Freyja.Effects.Coroutine do
  @moduledoc """
  The Coroutine effect signature
  """
  import Freyja.Freer.Sig.DefEffectStruct
  alias Freyja.Freer

  def_effect_struct(Yield, value: nil)

  @spec yield(any) :: Freer.t()
  def yield(value), do: %Yield{value: value} |> Freer.send_effect()

  defmodule Suspend do
    @moduledoc """
    Internal marker struct used by Coroutine.Handler to communicate suspension to Run.
    This is part of the private protocol between Coroutine handler and Run.do_run.
    Run converts this to {:suspend, value, continuation} in RunOutcome.result.
    """
    defstruct value: nil, continuation: nil

    @type t :: %__MODULE__{value: any, continuation: (any -> Freyja.Freer.t())}
  end
end

defmodule Freyja.Effects.Coroutine.Handler do
  @moduledoc """
  A coroutine effect implementation using the Freer monad.
  Provides yield operation that suspends computation and returns a value to the caller.
  The computation can be resumed by providing a value that becomes the result of the yield operation.

  Based on the Haskell implementation in Control.Monad.Freer.Coroutine.
  """

  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.Coroutine.Suspend
  alias Freyja.Effects.Coroutine.Yield
  alias Freyja.Run.RunState

  @behaviour Freyja.Freer.EffectHandler

  @impl Freyja.Freer.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == Coroutine
  end

  @doc """
  Interpret a coroutine and report its status.
  Returns Suspend struct which Run.do_run converts to {:suspend, value, continuation}.
  """
  @impl Freyja.Freer.EffectHandler
  def interpret(
        %Impure{sig: Coroutine, data: u, q: q} = _computation,
        _handler_key,
        state,
        %RunState{}
      ) do
    case u do
      %Yield{value: val} ->
        case state do
          %{resume_value: resume_val} ->
            # Resuming! Continue with resume_value instead of suspending
            next = Impl.q_apply(q, resume_val)
            # Clear resume_value so subsequent yields suspend normally
            {next, Map.delete(state, :resume_value)}

          _ ->
            # Normal suspend
            k = fn v -> Impl.q_apply(q, v) end
            {Freer.return(%Suspend{value: val, continuation: k}), state}
        end
    end
  end

  @doc """
  Wrap completed computations in {:done, value}.

  Suspensions bypass finalize (via Run.do_run), so only completed values reach here.
  This creates a consistent result shape when Coroutine is in the handler stack.
  """
  @impl Freyja.Freer.EffectHandler
  def finalize(%Pure{val: val}, _key, state, _run_state) do
    # Wrap completed values in {:done, _}
    # Suspensions already bypass finalize, so they stay as {:suspend, _, _}
    {%Pure{val: {:done, val}}, state}
  end

  @doc """
  Add this handler to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      computation |> Coroutine.Handler.run()

      # With resume_value for resuming suspended computations
      builder |> Coroutine.Handler.run(%{resume_value: 42})
  """
  def run(computation_or_builder, initial_state \\ :__default__) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
  end
end
