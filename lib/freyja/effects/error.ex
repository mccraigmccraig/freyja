defmodule Freyja.Effects.Error do
  @moduledoc "Operations (Ops) for the Error effect"
  import Freyja.Freer.Sig.DefEffectStruct

  def_effect_struct(Throw, error: nil)
  def_effect_struct(Catch, computation: nil, handler: nil)

  def throw_fx(err), do: %Throw{error: err}
  def catch_fx(computation, handler), do: %Catch{computation: computation, handler: handler}
end

defmodule Freyja.Effects.Error.Handler do
  @moduledoc "Interpreter (handler) for the Error effect"

  require Logger

  alias Freyja.ErrorResult
  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.Error
  alias Freyja.Effects.Error.Throw
  alias Freyja.Effects.Error.Catch
  alias Freyja.Run
  alias Freyja.Run.RunEffects
  alias Freyja.Run.RunEffects.ScopedError
  alias Freyja.Run.RunEffects.ScopedOk
  alias Freyja.Run.RunState
  alias Freyja.RunOutcome
  alias Freyja.ErrorResult
  alias Freyja.OkResult
  alias Freyja.SuspendResult

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
    sig == Error
  end

  @doc "Interpret an Error computation, handling throw/catch"
  @impl Freyja.EffectHandler
  def interpret(
        %Freer.Impure{sig: Error, data: u, q: q} = _computation,
        _handler_key,
        _state,
        %RunState{} = run_state
      ) do
    case u do
      %Throw{error: err} ->
        # Logger.error("#{__MODULE__}.throw")
        # throw shoft-circuits - discards queue
        {Freyja.ErrorResult.error(err) |> Freer.return(), nil}

      %Catch{computation: inner, handler: handler} ->
        # {%Pure{val: result}, updated_run_state}
        inner_outcome = Run.run(inner, run_state)

        {
          handle_inner_outcome(inner_outcome, handler, q),
          nil
        }
    end
  end

  defp handle_inner_outcome(
         %RunOutcome{result: result} = inner_outcome,
         handler,
         q
       ) do
    # Logger.error("#{__MODULE__}.catch #{inspect(inner_outcome, pretty: true)}")

    case result do
      %ErrorResult{error: err} ->
        if !is_nil(handler) do
          # pass nil to next handle_inner_outcome
          handler.(err)
          # do_run doesn't re-initialize
          |> Run.do_run(inner_outcome.run_state)
          |> handle_inner_outcome(nil, q)
        else
          %Impure{
            sig: RunEffects,
            data: %ScopedError{
              error: err,
              run_outcome: inner_outcome
            },
            q: q
          }
        end

      %SuspendResult{value: value, continuation: _scoped_continuation} ->
        # this is a bit tricky - we need to immediately return to the
        # outer computation, resume with the scoping
        # still active, and be careful not to double call the continuations
        # in q
        resume_catch_k = fn resumed_value ->
          updated_outcome = Run.resume(inner_outcome, resumed_value)

          handle_inner_outcome(updated_outcome, handler, q)
        end

        # tricky - don't prepend the suspend continuation to the q,
        # rather,just return the resume continuatino, and once we've
        # resumed we'll get the rest of the queue back from the
        # closure
        Impl.bindp(Coroutine.yield(value), [resume_catch_k])

      %OkResult{value: val} ->
        # Logger.error(
        #   "#{__MODULE__}.OkResult\n" <>
        #     "inner_outcome: #{inspect(inner_outcome, pretty: true)}"
        # )

        %Impure{
          sig: RunEffects,
          data: %ScopedOk{
            value: val,
            run_outcome: inner_outcome
          },
          q: q
        }
    end
  end
end
