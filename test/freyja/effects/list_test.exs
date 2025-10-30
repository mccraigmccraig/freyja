defmodule Freyja.Effects.ListTest do
  use ExUnit.Case

  require Logger

  import Freyja.Con

  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.List
  alias Freyja.Effects.State
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

  defcon multiply_and_sum(element), [Coroutine, State] do
    y <- yield(element)
    product <- return(element * y)
    current_sum <- get()
    put(current_sum + product)
    return(product)
  end

  defcon process_list_with_state(l), [List] do
    products <- fx_map(l, &multiply_and_sum/1)
    return(products)
  end

  describe "map with state" do
    test "it maps with coroutine and maintains state sum" do
      runner =
        Run.with_handlers(
          logger: Freyja.Effects.EffectLogger.Handler,
          l: List.Handler,
          c: Coroutine.Handler,
          s: {State.Handler, 0}
        )

      input = [10, 20, 30]
      # Yield responses - multiply each element by these
      responses = [2, 3, 4]

      computation = process_list_with_state(input)

      # feed the coroutine yields with responses
      final_outcome =
        Enum.reduce(
          responses,
          Run.run(computation, runner),
          fn response, outcome ->
            Run.resume(outcome, response)
          end
        )

      # Products: [10*2, 20*3, 30*4] = [20, 60, 120]
      assert final_outcome.result == %Freyja.OkResult{
               value: [20, 60, 120]
             }

      # Sum: 20 + 60 + 120 = 200
      assert final_outcome.outputs.s == 200

      Logger.error(
        "#{__MODULE__}.map_with_state_outcome\n" <>
          inspect(final_outcome.outputs.logger, pretty: true)
      )
    end
  end
end
