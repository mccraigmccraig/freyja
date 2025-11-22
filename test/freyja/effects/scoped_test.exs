defmodule Freyja.Effects.ScopedTest do
  use ExUnit.Case

  require Logger

  use Freyja.Syntax

  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.Writer
  alias Freyja.Run
  alias Freyja.Effects.{Lift, Throw}
  alias Freyja.Effects.Catch

  defmodule ScopedFx do
    defcon suspend_twice(a, b), [Coroutine, Writer] do
      first <- yield(a)
      _ <- tell(first)

      _ <- if first == "boo", do: Throw.throw_error(:boo), else: return(:ok)

      second <- yield(b)
      _ <- tell(second)

      _ <- if second == "hoo", do: Throw.throw_error(:hoo), else: return(:ok)

      result <- return(%{a: a, b: b, first: first, second: second})
      _ <- tell(result)
      return(result)
    end

    # catch establishes a scope - the contained computation is
    # run inside the scope - now using defhefty with catch clause
    defhefty catch_suspend_twice(a, b) do
      r <- Lift.lift(suspend_twice(a, b))
      _ <- Writer.tell(:completed)
      return(Map.put(r, :extra, "extra!"))
    catch
      :boo ->
        _ <- Writer.tell(:caught)
        return(:oops)
    end

    defhefty safe_suspend_twice(a, b) do
      _ <- Writer.tell(:before)
      r <- catch_suspend_twice(a, b)
      _ <- Writer.tell(:after)
      return(r)
    end
  end

  # These tests verify that catch scope is preserved across coroutine suspensions.
  # With the new interposition-based approach, the catch interception is baked into
  # the computation structure, so it IS preserved across suspensions.
  describe "suspending a scoped effect" do
    test "it suspends" do
      outcome_one =
        ScopedFx.safe_suspend_twice(10, 20)
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Coroutine.Handler.run()
        |> Writer.Handler.run([])
        |> Run.run()

      outcome_two = Run.resume(outcome_one, "one")
      outcome_three = Run.resume(outcome_two, "two")

      assert {:done,
              {:ok,
               %{
                 a: 10,
                 b: 20,
                 first: "one",
                 second: "two",
                 extra: "extra!"
               }}} == outcome_three.result

      writer_output = outcome_three.outputs[Writer.Handler]
      assert :before in writer_output
      assert :completed in writer_output
      assert :after in writer_output
      assert "one" in writer_output
      assert "two" in writer_output
    end

    test "the scope is still in effect after resume" do
      outcome_one =
        ScopedFx.safe_suspend_twice(10, 20)
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Coroutine.Handler.run()
        |> Writer.Handler.run([])
        |> Run.run()

      # Logger.error("#{__MODULE__}.outcome_one: #{inspect(outcome_one, pretty: true)}")

      outcome_two = Run.resume(outcome_one, "boo")

      # With interposition, catch scope IS preserved after suspension/resume!
      # The catch handler catches :boo and returns :oops (wrapped in {:ok, } and {:done, })
      assert {:done, {:ok, :oops}} == outcome_two.result
    end

    test "uncaught errors propagate out" do
      outcome_one =
        ScopedFx.safe_suspend_twice(10, 20)
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> Throw.Handler.run()
        |> Coroutine.Handler.run()
        |> Writer.Handler.run([])
        |> Run.run()

      outcome_two = Run.resume(outcome_one, "one")
      outcome_three = Run.resume(outcome_two, "hoo")

      assert {:done, {:error, :hoo}} == outcome_three.result

      # With Hefty non-transactional semantics, state changes persist
      # Check that writer has some output
      assert is_list(outcome_three.outputs[Writer.Handler])
    end
  end
end
