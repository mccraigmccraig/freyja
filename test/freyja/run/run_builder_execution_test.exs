defmodule Freyja.Run.RunBuilderExecutionTest do
  use ExUnit.Case

  import Freyja.Freer.FreerBlock
  use Freyja.Syntax

  alias Freyja.Run
  alias Freyja.Run.RunOutcome
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.Effects.Throw
  alias Freyja.Effects.{Lift, Catch}

  describe "Run.run/1 with RunBuilder" do
    test "executes Freer computation" do
      computation =
        con State do
          x <- get()
          _ <- put(x + 10)
          y <- get()
          return(y)
        end

      outcome =
        computation
        |> State.Handler.run(5)
        |> Run.run()

      assert %RunOutcome{result: 15} = outcome
      assert outcome.outputs[State.Handler] == 15
    end

    test "executes Freer with multiple handlers" do
      computation =
        con [State, Writer] do
          _ <- put(10)
          _ <- tell("hello")
          x <- get()
          _ <- tell("world")
          return(x * 2)
        end

      outcome =
        computation
        |> State.Handler.run(0)
        |> Writer.Handler.run([])
        |> Run.run()

      assert outcome.result == 20
      assert outcome.outputs[State.Handler] == 10
      assert outcome.outputs[Writer.Handler] == ["world", "hello"]
    end

    test "executes Hefty computation" do
      computation =
        hefty do
          x <- Lift.lift(State.get())
          _ <- Lift.lift(State.put(x + 5))
          y <- Lift.lift(State.get())
          return(y)
        end

      outcome =
        computation
        |> Lift.Algebra.run()
        |> State.Handler.run(10)
        |> Run.run()

      assert outcome.result == 15
      assert outcome.outputs[State.Handler] == 15
    end

    test "executes Hefty with Catch" do
      computation =
        hefty do
          result <-
            Catch.catch_hefty(
              hefty do
                x <- Lift.lift(State.get())

                if x > 5 do
                  Lift.lift(Throw.throw_error(:too_big))
                else
                  return({:ok, x})
                end
              end,
              fn err -> Freyja.Hefty.pure({:error, err}) end
            )

          return(result)
        end

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(10)
        |> Throw.Handler.run()
        |> Run.run()

      # Catch handler returns {:error, :too_big} as a normal value
      # Throw.Handler wraps ALL normal values in {:ok, _}
      assert outcome.result == {:ok, {:error, :too_big}}
    end
  end

  describe "Run.eval/1" do
    test "returns only result value" do
      computation =
        con State do
          x <- get()
          return(x * 2)
        end

      result =
        computation
        |> State.Handler.run(21)
        |> Run.eval()

      assert result == 42
    end
  end

  describe "Run.exec/1" do
    test "returns only outputs map" do
      computation =
        con [State, Writer] do
          _ <- put(10)
          _ <- tell("hello")
          return(:done)
        end

      outputs =
        computation
        |> State.Handler.run(0)
        |> Writer.Handler.run([])
        |> Run.exec()

      assert outputs[State.Handler] == 10
      assert outputs[Writer.Handler] == ["hello"]
    end
  end

  describe "Run.rerun/2" do
    test "reruns with previous outputs as initial states" do
      computation =
        con State do
          x <- get()
          _ <- put(x + 1)
          return(x)
        end

      builder = computation |> State.Handler.run(0)

      outcome1 = Run.run(builder)
      assert outcome1.result == 0
      assert outcome1.outputs[State.Handler] == 1

      # Rerun with state=1 from outcome1
      outcome2 = Run.rerun(builder, outcome1)
      assert outcome2.result == 1
      assert outcome2.outputs[State.Handler] == 2

      # Rerun again with state=2
      outcome3 = Run.rerun(builder, outcome2)
      assert outcome3.result == 2
      assert outcome3.outputs[State.Handler] == 3
    end

    test "reruns with multiple handlers" do
      computation =
        con [State, Writer] do
          x <- get()
          _ <- put(x + 1)
          _ <- tell("iteration")
          return(x)
        end

      builder =
        computation
        |> State.Handler.run(0)
        |> Writer.Handler.run([])

      outcome1 = Run.run(builder)
      assert outcome1.result == 0
      assert outcome1.outputs[Writer.Handler] == ["iteration"]

      # Rerun - should accumulate in Writer
      outcome2 = Run.rerun(builder, outcome1)
      assert outcome2.result == 1
      assert outcome2.outputs[Writer.Handler] == ["iteration", "iteration"]
    end
  end
end
