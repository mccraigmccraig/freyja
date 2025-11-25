defmodule Freyja.Effects.ChangesTest do
  use ExUnit.Case, async: true
  use Freyja.Syntax

  alias Freyja.Effects.{Changes, Lift, Catch, Throw}
  alias Freyja.Run

  describe "handler safety" do
    test "change without capture raises" do
      comp =
        con [Changes] do
          Changes.change(:orphan)
        end

      assert_raise RuntimeError, fn ->
        comp
        |> Changes.Handler.run()
        |> Run.run()
      end
    end

    test "nested capture is rejected" do
      comp =
        hefty do
          Changes.capture(
            hefty do
              Changes.capture(
                hefty do
                  return(:nested)
                end
              )
            end
          )
        end

      assert_raise ArgumentError, fn ->
        comp
        |> Changes.Algebra.run()
        |> Changes.Handler.run()
        |> Run.run()
      end
    end
  end

  describe "capture semantics" do
    test "captures changes in order" do
      comp =
        hefty do
          {result, captured} <-
            Changes.capture(
              hefty do
                _ <- Lift.lift(Changes.change(:first))
                _ <- Lift.lift(Changes.change(:second))
                return(:done)
              end
            )

          return({result, captured})
        end

      outcome =
        comp
        |> Changes.Algebra.run()
        |> Lift.Algebra.run()
        |> Changes.Handler.run()
        |> Run.run()

      assert outcome.result == {:done, [:first, :second]}
    end

    test "aborted capture frees tag for reuse" do
      comp =
        hefty do
          _ <-
            Catch.catch_hefty(
              Changes.capture(
                hefty do
                  _ <- Lift.lift(Changes.change(:before))
                  _ <- Lift.lift(Throw.throw_error(:boom))
                  return(:never)
                end
              ),
              fn _err ->
                hefty do
                  return(:handled)
                end
              end
            )

          {result, captured} <-
            Changes.capture(
              hefty do
                _ <- Lift.lift(Changes.change(:after))
                return(:ok)
              end
            )

          return({result, captured})
        end

      outcome =
        comp
        |> Catch.Algebra.run()
        |> Changes.Algebra.run()
        |> Lift.Algebra.run()
        |> Changes.Handler.run()
        |> Run.run()

      assert outcome.result == {:ok, [:after]}
    end
  end
end
