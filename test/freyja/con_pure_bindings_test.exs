defmodule Freyja.ConPureBindingsTest do
  use ExUnit.Case

  use Freyja.Syntax

  alias Freyja.Effects.State
  alias Freyja.Run
  alias Freyja.Run.RunOutcome

  describe "pure variable bindings with =" do
    test "simple pure binding" do
      computation =
        con State do
          x <- get()
          doubled = x * 2
          return(doubled)
        end

      outcome =
        computation
        |> State.Handler.run(10)
        |> Run.run()

      assert %RunOutcome{
               result: 20
             } = outcome
    end

    test "multiple pure bindings" do
      computation =
        con State do
          x <- get()
          doubled = x * 2
          tripled = x * 3
          sum = doubled + tripled
          return(sum)
        end

      outcome =
        computation
        |> State.Handler.run(5)
        |> Run.run()

      assert %RunOutcome{
               result: 25
             } = outcome
    end

    test "pure bindings mixed with effects" do
      computation =
        con State do
          x <- get()
          doubled = x * 2
          _ <- put(doubled)
          y <- get()
          halved = y / 2
          return({doubled, y, halved})
        end

      outcome =
        computation
        |> State.Handler.run(10)
        |> Run.run()

      assert %RunOutcome{
               result: {20, 20, 10.0},
               outputs: %{State.Handler => 20}
             } = outcome
    end

    test "pure bindings with function calls" do
      pure_fn = fn a, b -> a * b + 100 end

      computation =
        con State do
          x <- get()
          result = pure_fn.(x, 3)
          _ <- put(result)
          return(result)
        end

      outcome =
        computation
        |> State.Handler.run(7)
        |> Run.run()

      assert %RunOutcome{
               result: 121,
               outputs: %{State.Handler => 121}
             } = outcome
    end

    test "pure bindings with pattern matching" do
      computation =
        con State do
          x <- get()
          {a, b} = {x * 2, x * 3}
          sum = a + b
          return(sum)
        end

      outcome =
        computation
        |> State.Handler.run(4)
        |> Run.run()

      assert %RunOutcome{
               result: 20
             } = outcome
    end

    test "pure bindings with complex expressions" do
      computation =
        con State do
          x <- get()

          # Complex pure computation
          calculated =
            case x do
              n when n > 10 -> n * 2
              n -> n * 3
            end

          _ <- put(calculated)
          final <- get()
          return({x, calculated, final})
        end

      outcome =
        computation
        |> State.Handler.run(5)
        |> Run.run()

      assert %RunOutcome{
               result: {5, 15, 15},
               outputs: %{State.Handler => 15}
             } = outcome
    end

    test "pure bindings referencing previous pure bindings" do
      computation =
        con State do
          x <- get()
          a = x + 10
          b = a * 2
          c = b - 5
          _ <- put(c)
          return({a, b, c})
        end

      outcome =
        computation
        |> State.Handler.run(5)
        |> Run.run()

      assert %RunOutcome{
               result: {15, 30, 25},
               outputs: %{State.Handler => 25}
             } = outcome
    end
  end
end
