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
  require Logger

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
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
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

      %FxReduceList{list: l, init: init, f: f} ->
        {
          run_reduce_list(init, l, f, q, run_state),
          nil
        }
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
        # Logger.error("#{__MODULE__}.map_list OkResult... q: #{inspect(q, pretty: true)}")

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
        # Logger.error("#{__MODULE__}.map_list ErrorResult... q: #{inspect(q, pretty: true)}")

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

        # this is tricky - we _don't_ prepend the suspend
        # continuation to the q, because that leads to the q getting
        # duplicated by however many suspends there are... by
        # Impl.apply... so we just return the resume continuation,
        # and return the original q when we terminate with an
        # ScopedOk, or ScopedError
        Impl.bindp(Coroutine.scoped_yield(yield_value), [resume_map_k])
    end
  end

  defp run_reduce_list(acc, remaining = [first | _rest], f, q, run_state) do
    f.(first, acc)
    |> Run.run(run_state)
    |> reduce_list(remaining, f, q)
  end

  # Tail-recursive reduce operation, supporting yield
  # Threads accumulator through effectful reducer function
  # Terminates on error or list exhaustion, yields when reducer requests
  #
  # Each invocation of the reducer function establishes a new scope
  # under the FxReduceList effect
  defp reduce_list(inner_outcome, remaining = [_first | rest], f, q) do
    case inner_outcome do
      %RunOutcome{result: %OkResult{value: new_acc}} ->
        # Logger.error("#{__MODULE__}.reduce_list OkResult...")

        if Enum.empty?(rest) do
          # Done - return final accumulator
          %Impure{
            sig: RunEffects,
            data: %RunEffects.ScopedOk{
              value: new_acc,
              run_outcome: inner_outcome
            },
            q: q
          }
        else
          # Continue with next element and updated accumulator
          run_reduce_list(new_acc, rest, f, q, inner_outcome.run_state)
        end

      %RunOutcome{result: %ErrorResult{error: err}} ->
        # Logger.error("#{__MODULE__}.reduce_list ErrorResult...")

        # Error - short circuit
        %Impure{
          sig: RunEffects,
          data: %RunEffects.ScopedError{
            error: err,
            run_outcome: inner_outcome
          },
          q: q
        }

      %RunOutcome{result: %SuspendResult{value: yield_value}} ->
        # Suspend - create resume continuation
        resume_reduce_k = fn resumed_value ->
          next_outcome = Run.resume(inner_outcome, resumed_value)
          reduce_list(next_outcome, remaining, f, q)
        end

        # Same trick as map_list - don't prepend to q to avoid duplication
        Impl.bindp(Coroutine.scoped_yield(yield_value), [resume_reduce_k])
    end
  end
end
