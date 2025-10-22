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

  describe "map" do
    test "it maps a list" do
      runner =
        Run.with_handlers(
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

      # Logger.error("#{__MODULE__}.outcome\n" <> inspect(final_outcome, pretty: true))
    end
  end
end
