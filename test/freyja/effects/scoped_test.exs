defmodule Freyja.Effects.ScopedTest do
  use ExUnit.Case

  require Logger

  alias Freyja.Effects.Coroutine
  alias Freyja.Effects.Error
  alias Freyja.Run

  defmodule ScopedFx do
    import Freyja.Con

    defcon suspend_twice(a, b), [Coroutine, Error] do
      first <- yield(a)

      if first == "boo" do
        throw_fx(:boo)
      else
        return(:ok)
      end

      second <- yield(b)

      return(%{a: a, b: b, first: first, secomd: second})
    end

    defcon safe_suspend_twice(a, b), [Error] do
      suspend_twice(a, b)
    catch
      _ -> return(:oops)
    end
  end

  describe "suspending a scoped effect" do
    test "it suspends" do
      runner = Run.with_handlers(e: Error.Handler, c: Coroutine.Handler)

      outcome_one = ScopedFx.safe_suspend_twice(10, 20) |> Run.run(runner)
      outcome_two = outcome_one |> Run.resume("one")
      outcome_three = outcome_two |> Run.resume("two")

      assert %{
               a: 10,
               b: 20,
               first: "one",
               secomd: "two"
             } == outcome_three.result.value

      Logger.error("#{__MODULE__}.outcome_one: #{inspect(outcome_one, pretty: true)}")
      Logger.error("#{__MODULE__}.outcome_two: #{inspect(outcome_two, pretty: true)}")
      Logger.error("#{__MODULE__}.outcome_three: #{inspect(outcome_three, pretty: true)}")
    end

    test "it errors" do
      runner = Run.with_handlers(e: Error.Handler, c: Coroutine.Handler)

      outcome_one = ScopedFx.safe_suspend_twice(10, 20) |> Run.run(runner)

      Logger.error("#{__MODULE__}.outcome_one: #{inspect(outcome_one, pretty: true)}")

      outcome_two = outcome_one |> Run.resume("boo")

      Logger.error("#{__MODULE__}.outcome_two: #{inspect(outcome_one, pretty: true)}")

      outcome_three = outcome_two |> Run.resume("two")

      assert %{
               a: 10,
               b: 20,
               first: "one",
               secomd: "two"
             } == outcome_three.result.value
    end
  end
end
