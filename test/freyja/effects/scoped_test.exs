defmodule Freyja.Effects.ScopedTest do
  use ExUnit.Case

  require Logger

  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.Error
  alias Freyja.Effects.Writer
  alias Freyja.ErrorResult
  alias Freyja.Run

  defmodule ScopedFx do
    import Freyja.Con

    defcon suspend_twice(a, b), [Coroutine, Error, Writer] do
      first <- yield(a)
      tell(first)

      if first == "boo", do: throw_fx(:boo), else: return(:ok)

      second <- yield(b)
      tell(second)

      if second == "hoo", do: throw_fx(:hoo), else: return(:ok)

      result <- return(%{a: a, b: b, first: first, second: second})
      tell(result)
      return(result)
    end

    # catch establishes a scope - the contained computation is
    # run inside the scope
    defcon catch_suspend_twice(a, b), [Error, Writer] do
      r <- suspend_twice(a, b)
      tell(:completed)
      return(Map.put(r, :extra, "extra!"))
    catch
      :boo ->
        tell(:caught)
        return(:oops)
    end

    defcon safe_suspend_twice(a, b), [Error, Writer] do
      tell(:before)
      r <- catch_suspend_twice(a, b)
      tell(:after)
      return(r)
    end
  end

  describe "suspending a scoped effect" do
    test "it suspends" do
      runner =
        Run.with_handlers(
          e: Error.Handler,
          c: Coroutine.Handler,
          w: Writer.Handler
        )

      outcome_one = ScopedFx.safe_suspend_twice(10, 20) |> Run.run(runner)
      outcome_two = outcome_one |> Run.resume("one")
      outcome_three = outcome_two |> Run.resume("two")

      assert %{
               a: 10,
               b: 20,
               first: "one",
               second: "two",
               extra: "extra!"
             } == outcome_three.result.value

      assert [
               :after,
               :completed,
               %{a: 10, b: 20, first: "one", second: "two"},
               "two",
               "one",
               :before
             ] =
               outcome_three.outputs.w
    end

    test "the scope is still in effect after resume" do
      runner =
        Run.with_handlers(
          e: Error.Handler,
          c: Coroutine.Handler,
          w: Writer.Handler
        )

      outcome_one = ScopedFx.safe_suspend_twice(10, 20) |> Run.run(runner)

      # Logger.error("#{__MODULE__}.outcome_one: #{inspect(outcome_one, pretty: true)}")

      outcome_two = outcome_one |> Run.resume("boo")

      assert :oops == outcome_two.result.value

      # after a recovery, the state changes from the scoped effect are preserved
      assert [:after, :caught, "boo", :before] = outcome_two.outputs.w
    end

    test "uncaught errors propagate out" do
      runner =
        Run.with_handlers(
          e: Error.Handler,
          c: Coroutine.Handler,
          w: Writer.Handler
        )

      outcome_one = ScopedFx.safe_suspend_twice(10, 20) |> Run.run(runner)
      outcome_two = outcome_one |> Run.resume("one")
      outcome_three = outcome_two |> Run.resume("hoo")

      assert %ErrorResult{error: :hoo} == outcome_three.result

      # after an error, state changes from the scoped effect are discarded
      assert [:before] = outcome_two.outputs.w
    end
  end
end
