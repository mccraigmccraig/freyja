defmodule Freyja.Effects.ListTest do
  use ExUnit.Case

  require Logger

  import Freyja.Con

  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.List
  alias Freyja.Run

  defcon yield_to_pair(a), [Coroutine] do
    r <- yield(a)
    return({a, r})
  end

  defcon make_pairs(l), [List] do
    # fx_map is like Enum.map, but allows effects
    # including Coroutine.yield in the mapper function
    r <- fx_map(l, &yield_to_pair/1)
    return(r)
  end

  defcon yield_sum(element, acc), [Coroutine] do
    r <- yield({element, acc})
    return(acc + r)
  end

  defcon sum_with_yield(l), [List] do
    # fx_reduce is like Enum.reduce, but allows effects
    # including Coroutine.yield in the reducer function
    r <- fx_reduce(l, 0, &yield_sum/2)
    return(r)
  end

  describe "map" do
    test "it maps a list" do
      runner =
        Run.with_handlers(
          logger: Freyja.Effects.EffectLogger.Handler,
          l: List.Handler,
          c: Coroutine.Handler
        )

      input = [:foo, :bar, :baz]
      responses = [10, 20, 30]

      computation = make_pairs(input)

      # feed the coroutine yields with responses
      final_outcome =
        Enum.reduce(
          responses,
          Run.run(computation, runner),
          fn response, outcome ->
            Run.resume(outcome, response)
          end
        )

      assert final_outcome.result == %Freyja.OkResult{
               value: [
                 {:foo, 10},
                 {:bar, 20},
                 {:baz, 30}
               ]
             }

      Logger.error(
        "#{__MODULE__}.outcome\n" <> inspect(final_outcome.outputs.logger, pretty: true)
      )
    end
  end

  describe "reduce" do
    test "it reduces a list" do
      runner =
        Run.with_handlers(
          logger: Freyja.Effects.EffectLogger.Handler,
          l: List.Handler,
          c: Coroutine.Handler
        )

      input = [10, 20, 30]
      # Responses to yields: each yields {element, acc}, we respond with element value
      responses = [10, 20, 30]

      computation = sum_with_yield(input)

      # feed the coroutine yields with responses
      final_outcome =
        Enum.reduce(
          responses,
          Run.run(computation, runner),
          fn response, outcome ->
            Run.resume(outcome, response)
          end
        )

      # Expected: 0 + 10 + 20 + 30 = 60
      assert final_outcome.result == %Freyja.OkResult{value: 60}

      Logger.error(
        "#{__MODULE__}.reduce_outcome\n" <> inspect(final_outcome.outputs.logger, pretty: true)
      )
    end
  end
end
