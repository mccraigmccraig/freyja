defmodule Freyja.Effects.List do
  @moduledoc """
  Operations in the List effect
  """
  import Freyja.Sig.DefEffectStruct

  def_effect_struct(FxMapList, list: [], f: nil)
  def_effect_struct(FxReduceList, list: [], init: nil, f: nil)

  @doc """
  map an effectful function (any -> freer) over a list
  """
  def fx_map(l, f), do: %FxMapList{list: l, f: f}

  @doc """
  reduce a list with an effectful function (element,acc -> freer)
  """
  def fx_reduce(l, init, f), do: %FxReduceList{list: l, init: init, f: f}
end

defmodule Freyja.Effects.List.Handler do
  @moduledoc """
  A handler for the List effect
  """

  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.List
  alias Freyja.Effects.List.FxMapList
  alias Freyja.Effects.List.FxReduceList
  alias Freyja.Run.RunState
  alias Freyja.Run
  alias Freyja.RunOutcome
  alias Freyja.OkResult
  alias Freyja.SuspendResult
  alias Freyja.ErrorResult
  alias Freyja.Run.RunEffects

  defmodule MapState do
    defstruct results: [], remaining: []
  end

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}) do
    sig == List
  end

  @impl Freyja.EffectHandler
  def interpret(
        %Freer.Impure{sig: List, data: u, q: q} = _computation,
        _handler_key,
        _state,
        %RunState{} = run_state
      ) do
    case u do
      %FxMapList{list: l, f: f} ->
        {
          run_map_list([], l, f, q, run_state),
          nil
        }

        # %FxReduceList{list: l, init: init, f: f} ->
        #   {Impl.q_apply(q, state), state}
    end
  end

  defp run_map_list(results, remaining = [first | _rest], f, q, run_state) do
    f.(first)
    |> Run.run(run_state)
    |> map_list(results, remaining, f, q)
  end

  # it's a tail-recursive map operation, supporting yield
  # it repeatedly calls the mapper function, terminating
  # permanently on an error or when the list is exhausted,
  # and yielding when the mapper requests
  #
  # Each invocation of the mapper function establishes a new scope
  # under the FxMapList effect
  defp map_list(inner_outcome, results, remaining = [_first | rest], f, q) do
    case inner_outcome do
      %RunOutcome{result: %OkResult{value: value}} ->
        if Enum.empty?(rest) do
          %Impure{
            sig: RunEffects,
            data: %RunEffects.ScopedOk{
              value: Enum.reverse([value | results]),
              run_outcome: inner_outcome
            },
            q: q
          }
        else
          run_map_list([value | results], rest, f, q, inner_outcome.run_state)
        end

      %RunOutcome{result: %ErrorResult{error: err}} ->
        %Impure{
          sig: RunEffects,
          data: %RunEffects.ScopedError{
            error: err,
            run_outcome: inner_outcome
          },
          q: q
        }

      %RunOutcome{result: %SuspendResult{value: yield_value}} ->
        resume_map_k = fn resumed_value ->
          next_outcome = Run.resume(inner_outcome, resumed_value)
          map_list(next_outcome, results, remaining, f, q)
        end

        updated_q = Impl.q_prepend(q, resume_map_k)

        Impl.bindp(Coroutine.yield(yield_value), updated_q)
    end
  end
end
