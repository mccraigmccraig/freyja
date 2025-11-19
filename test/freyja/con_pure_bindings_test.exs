defmodule Freyja.ConPureBindingsTest do
  use ExUnit.Case

  import Freyja.Con

  alias Freyja.Effects.State
  alias Freyja.Run
  alias Freyja.RunOutcome

  describe "pure variable bindings with =" do
    test "simple pure binding" do
      computation =
        con [State] do
          x <- get()
          doubled = x * 2
          return(doubled)
        end

      runner = Run.with_handlers(s: {State.Handler, 10})
      outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: 20
             } = outcome
    end

    test "multiple pure bindings" do
      computation =
        con [State] do
          x <- get()
          doubled = x * 2
          tripled = x * 3
          sum = doubled + tripled
          return(sum)
        end

      runner = Run.with_handlers(s: {State.Handler, 5})
      outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: 25
             } = outcome
    end

    test "pure bindings mixed with effects" do
      computation =
        con [State] do
          x <- get()
          doubled = x * 2
          put(doubled)
          y <- get()
          halved = y / 2
          return({doubled, y, halved})
        end

      runner = Run.with_handlers(s: {State.Handler, 10})
      outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: {20, 20, 10.0},
               outputs: %{s: 20}
             } = outcome
    end

    test "pure bindings with function calls" do
      pure_fn = fn a, b -> a * b + 100 end

      computation =
        con [State] do
          x <- get()
          result = pure_fn.(x, 3)
          put(result)
          return(result)
        end

      runner = Run.with_handlers(s: {State.Handler, 7})
      outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: 121,
               outputs: %{s: 121}
             } = outcome
    end

    test "pure bindings with pattern matching" do
      computation =
        con [State] do
          x <- get()
          {a, b} = {x * 2, x * 3}
          sum = a + b
          return(sum)
        end

      runner = Run.with_handlers(s: {State.Handler, 4})
      outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: 20
             } = outcome
    end

    test "pure bindings with complex expressions" do
      computation =
        con [State] do
          x <- get()

          # Complex pure computation
          calculated =
            case x do
              n when n > 10 -> n * 2
              n -> n * 3
            end

          put(calculated)
          final <- get()
          return({x, calculated, final})
        end

      runner = Run.with_handlers(s: {State.Handler, 5})
      outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: {5, 15, 15},
               outputs: %{s: 15}
             } = outcome
    end

    test "pure bindings referencing previous pure bindings" do
      computation =
        con [State] do
          x <- get()
          a = x + 10
          b = a * 2
          c = b - 5
          put(c)
          return({a, b, c})
        end

      runner = Run.with_handlers(s: {State.Handler, 5})
      outcome = computation |> Run.run(runner)

      assert %RunOutcome{
               result: {15, 30, 25},
               outputs: %{s: 25}
             } = outcome
    end
  end
end
