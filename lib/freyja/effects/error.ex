defmodule Freyja.Effects.Error do
  @moduledoc "Operations (Ops) for the Error effect"
  import Freyja.Sig.DefEffectStruct

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
  alias Freyja.Freer.Impure
  alias Freyja.Effects.Error
  alias Freyja.Effects.Error.Throw
  alias Freyja.Effects.Error.Catch
  alias Freyja.Run
  alias Freyja.Run.RunEffects
  alias Freyja.Run.RunEffects.ScopedError
  alias Freyja.Run.RunEffects.ScopedReturn
  alias Freyja.Run.RunEffects.ScopedSuspend
  alias Freyja.Run.RunState
  alias Freyja.RunOutcome
  alias Freyja.ErrorResult
  alias Freyja.OkResult
  alias Freyja.SuspendResult
  alias Freyja.Protocols.Result

  @behaviour Freyja.EffectHandler

  @impl Freyja.EffectHandler
  def handles?(%Impure{sig: sig, data: _data, q: _q}) do
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
        %RunOutcome{
          result: result
        } = inner_outcome = Run.run(inner, run_state)

        case result do
          %ErrorResult{error: err} ->
            handler.(err)
            |> Run.run(inner_outcome.run_state)
            |> case do
              %RunOutcome{result: %ErrorResult{}} = unrecovered_outcome ->
                # handling failed - rethrow original error, preserve queue
                # for handling later
                {%Impure{
                   sig: RunEffects,
                   data: %ScopedError{
                     error: err,
                     run_outcome: unrecovered_outcome
                   },
                   q: q
                 }, nil}

              %RunOutcome{result: result} = recovered_outcome ->
                val = Result.value(result)

                {%Impure{
                   sig: RunEffects,
                   data: %ScopedReturn{
                     computation: Freer.return(val),
                     run_outcome: recovered_outcome
                   },
                   q: q
                 }, nil}
            end

          %SuspendResult{value: value, continuation: _scoped_continuation} ->
            {%Impure{
               sig: RunEffects,
               data: %ScopedSuspend{
                 value: value,
                 run_outcome: inner_outcome
               },
               q: q
             }, nil}

          %OkResult{value: val} ->
            {%Impure{
               sig: RunEffects,
               data: %ScopedReturn{
                 computation: Freer.return(val),
                 run_outcome: inner_outcome
               },
               q: q
             }, nil}
        end
    end
  end
end
