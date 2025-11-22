defmodule Freyja.Run.PipeAPITest do
  use ExUnit.Case

  import Freyja.Freer.FreerBlock
  use Freyja.Syntax

  alias Freyja.Run.RunBuilder
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.Effects.Throw
  alias Freyja.Effects.{Lift, Catch}

  describe "Pipe-friendly handler API" do
    test "single handler with State" do
      computation =
        con State do
          x <- get()
          _ <- put(x + 10)
          y <- get()
          return(y)
        end

      builder = computation |> State.Handler.run(5)

      assert %RunBuilder{
               computation_type: :freer,
               handlers: [{State.Handler, 5}]
             } = builder
    end

    test "chain multiple handlers" do
      computation =
        con [State, Writer] do
          _ <- put(10)
          _ <- tell("hello")
          x <- get()
          return(x)
        end

      builder =
        computation
        |> State.Handler.run(0)
        |> Writer.Handler.run([])

      assert %RunBuilder{
               handlers: [
                 {State.Handler, 0},
                 {Writer.Handler, []}
               ]
             } = builder
    end

    test "handler with default state" do
      computation =
        con Writer do
          _ <- tell("hello")
          return(:ok)
        end

      builder = computation |> Writer.Handler.run()

      assert %RunBuilder{
               handlers: [{Writer.Handler, []}]
             } = builder
    end
  end

  describe "Pipe-friendly algebra API" do
    test "single algebra" do
      computation =
        hefty do
          x <- Lift.lift(State.get())
          return(x)
        end

      builder = computation |> Lift.Algebra.run()

      assert %RunBuilder{
               computation_type: :hefty,
               algebras: [Lift.Algebra]
             } = builder
    end

    test "chain multiple algebras" do
      computation =
        hefty do
          result <-
            Catch.catch_hefty(
              Freyja.Hefty.pure(42),
              fn _err -> Freyja.Hefty.pure(:caught) end
            )

          return(result)
        end

      builder =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()

      assert %RunBuilder{
               algebras: [Catch.Algebra, Lift.Algebra]
             } = builder
    end

    test "mix algebras and handlers" do
      computation =
        hefty do
          x <- Lift.lift(State.get())
          return(x * 2)
        end

      builder =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(21)
        |> Throw.Handler.run()

      assert %RunBuilder{
               computation_type: :hefty,
               algebras: [Catch.Algebra, Lift.Algebra],
               handlers: [
                 {State.Handler, 21},
                 {Throw.Handler, nil}
               ]
             } = builder
    end
  end
end
