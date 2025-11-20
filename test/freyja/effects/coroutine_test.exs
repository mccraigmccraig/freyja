defmodule Freyja.Effects.CoroutineTest do
  use ExUnit.Case

  require Logger
  import Freyja.Freer.FreerBlock

  alias Freyja.Freer
  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.Coroutine
  alias Freyja.Freer
  alias Freyja.RunOutcome
  alias Freyja.Run

  describe "basic coroutine operations" do
    test "simple yield and resume" do
      # Create a coroutine that yields a value and returns another
      computation =
        con Coroutine do
          a <- yield(42)
          return("finished: " <> inspect(a))
        end

      outcome = Run.run(computation, [Coroutine.Handler])
      assert %RunOutcome{result: {:suspend, 42, _k}} = outcome

      outcome2 = Run.resume(outcome, 100)
      assert %Freyja.RunOutcome{result: {:done, "finished: 100"}} = outcome2
    end

    test "multiple yields" do
      require Freer

      # Keep the simple test as well
      computation =
        con Coroutine do
          a <- yield("first")
          b <- yield("second: #{a}")
          return("final: #{a + b}")
        end

      # First yield
      outcome = Run.run(computation, [EffectLogger.Handler, Coroutine.Handler])
      assert %RunOutcome{result: {:suspend, "first", _k}} = outcome

      # looks like I needd to encode the difference between "rerunning" and
      # "resuming" after suspend... "resuming" after suspend should have the
      # log in its partially consumed state, while "rerunning" will follow
      # the computation from the beginning
      outcome2 = Run.resume(outcome, 100)
      assert %Freyja.RunOutcome{result: {:suspend, "second: 100", _k2}} = outcome2

      # Logger.error("#{__MODULE__}.outcome2\n#{inspect(outcome2, pretty: true)}")

      outcome3 = Run.resume(outcome2, 50)
      assert %Freyja.RunOutcome{result: {:done, "final: 150"}} = outcome3

      # Logger.error("#{__MODULE__}.outcome3\n#{inspect(outcome3, pretty: true)}")
    end

    # test "multiple yields" do
    #   require Freer

    #   # Create a coroutine that yields multiple values
    #   computation =
    #     Freer.con Ops do
    #       steps a <- yield(1),
    #             b <- yield(a + 1),
    #             c <- yield(b + 1) do
    #         Freer.return(c + 1)
    #       end
    #     end

    #   # Let's trace the execution manually to understand what's happening
    #   result = Coroutine.run(computation)
    #   %Thunks.Coroutine.Status.Continue{value: 1, continuation: k1} = Freer.run(result)

    #   resumed1 =
    #     Coroutine.resume(%Thunks.Coroutine.Status.Continue{value: 1, continuation: k1}, 2)

    #   %Thunks.Coroutine.Status.Continue{value: v2, continuation: k2} = Freer.run(resumed1)

    #   resumed2 =
    #     Coroutine.resume(%Thunks.Coroutine.Status.Continue{value: v2, continuation: k2}, 4)

    #   %Thunks.Coroutine.Status.Continue{value: v3, continuation: k3} = Freer.run(resumed2)

    #   resumed3 =
    #     Coroutine.resume(%Thunks.Coroutine.Status.Continue{value: v3, continuation: k3}, 8)

    #   %Thunks.Coroutine.Status.Done{value: v4} = Freer.run(resumed3)

    #   assert {v2, v3, v4} == {3, 5, 9}

    #   # try resuming with some different values

    #   # Resume with 10
    #   resumed10 =
    #     Coroutine.resume(%Thunks.Coroutine.Status.Continue{value: 1, continuation: k1}, 10)

    #   assert %Thunks.Coroutine.Status.Continue{value: 11, continuation: _k2} =
    #            Freer.run(resumed10)

    #   # Resume with 20
    #   resumed20 =
    #     Coroutine.resume(%Thunks.Coroutine.Status.Continue{value: v2, continuation: k2}, 20)

    #   assert %Thunks.Coroutine.Status.Continue{value: 21, continuation: _k3} =
    #            Freer.run(resumed20)

    #   # Resume with 30 and get final result
    #   resumed30 =
    #     Coroutine.resume(%Thunks.Coroutine.Status.Continue{value: v3, continuation: k3}, 30)

    #   assert %Thunks.Coroutine.Status.Done{value: 31} = Freer.run(resumed30)
    # end

    # test "run_collecting helper" do
    #   require Freer

    #   computation =
    #     Freer.con Ops do
    #       steps a <- yield(1),
    #             b <- yield(a + 1),
    #             c <- yield(b + 1) do
    #         Freer.return(a + b + c + 1)
    #       end
    #     end

    #   # Run to completion, collecting all yields
    #   # Each yield gets the same resume value (10)
    #   {final, yields} =
    #     Coroutine.run_collecting(computation, [], fn v, acc -> {v + 10, [v | acc]} end)

    #   # This is the actual value: 1 + 11 + 21 + 34
    #   assert final == 67
    #   assert yields == [1, 12, 23]
    # end

    # test "run_stream helper" do
    #   require Freer

    #   computation =
    #     Freer.con Ops do
    #       steps _ <- yield("first"),
    #             _ <- yield("second"),
    #             _ <- yield("third") do
    #         Freer.return("done")
    #       end
    #     end

    #   # Convert to a stream and collect results
    #   results = Coroutine.run_stream(computation) |> Enum.to_list()

    #   assert results == [
    #            {:yielded, "first"},
    #            {:yielded, "second"},
    #            {:yielded, "third"},
    #            {:result, "done"}
    #          ]
    # end
  end

  # describe "combining with other effects" do
  #   test "coroutine with state" do
  #     require Freer

  #     computation =
  #       Freyja.Con.con [Coroutine, Freyja.Effects.Reader, Freyja.Effects.Writer] do
  #         state <- get()
  #         r1 <- yield("State is: #{state}")
  #         put(state + r1)
  #         new_state <- get()
  #         r2 <- yield("New state is: #{new_state}")
  #         Freer.return("Final resume: #{r2}")
  #       end

  #     # First run the computation through the state handler with initial state 5
  #     result1 =
  #       computation
  #       |> Freyja.Effects.State.interpret_state(5)
  #       |> CoroutineHandler.interpret_coroutine()
  #       |> Freer.run()

  #     assert %RunOutcome{
  #              result: %Freyja.SuspendResult{value: "State is: 5", continuation: _k1}
  #            } =
  #              result1

  #     result2 = result1 |> CoroutineHandler.resume(10) |> Freer.run()

  #     assert %RunOutcome{
  #              result: %Freyja.SuspendResult{value: "New state is: 15", continuation: _k2}
  #            } = result2

  #     result3 = result2 |> CoroutineHandler.resume(100) |> Freer.run()

  #     assert %RunOutcome{
  #              result: %Freyja.OkResult{value: "Final resume: 100"},
  #              outputs: %{state: 15}
  #            } = result3
  #   end
  # end

  # describe "trying the everything handler" do
  #   test "everything handler" do
  #     require Freer

  #     computation =
  #       Freyja.Con.con [Coroutine, Freyja.Effects.Reader, Freyja.Effects.Writer] do
  #         state <- get()
  #         r1 <- yield("State is: #{state}")
  #         put(state + r1)
  #         new_state <- get()
  #         r2 <- yield("New state is: #{new_state}")
  #         Freer.return("Final resume: #{r2}")
  #       end

  #     result1 =
  #       computation
  #       |> State.interpret_state(5)
  #       |> CoroutineHandler.interpret_coroutine()
  #       |> Freer.run()

  #     result2 = result1 |> CoroutineHandler.resume(10) |> Freer.run()
  #     _result3 = result2 |> CoroutineHandler.resume(100) |> Freer.run()
  #   end
  # end
end
