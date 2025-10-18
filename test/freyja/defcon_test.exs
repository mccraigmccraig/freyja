defmodule Freyja.DefconTest do
  use ExUnit.Case

  alias Freyja.Effects.Reader
  alias Freyja.Effects.Writer
  alias Freyja.Effects.Error
  alias Freyja.Run

  defmodule DefconExample do
    import Freyja.Con

    defcon sum_env(a, b), [Reader] do
      c <- ask()
      return(a + b + c)
    end

    defconp write_and_sum(a, b), [Writer] do
      _ <- tell(a)
      _ <- tell(b)
      return(a + b)
    end

    def call_private(a, b) do
      write_and_sum(a, b)
    end

    defcon safe_div(a, b), [Error] do
      if b == 0 do
        throw_fx(:zero)
      else
        return(a / b)
      end
    catch
      :zero -> return(:infty)
    end

    defcon sum_and_log(a, b), [Reader, Writer] do
      s <- sum_env(a, b)
      _ <- tell({:sum, s})
      return(s)
    end

    defcon sum_twice(a, b), [Reader] do
      x <- sum_env(a, b)
      y <- sum_env(x, 0)
      return(y)
    end
  end

  test "defcon with Reader returns expected sum" do
    runner = Run.with_handlers(r: {Reader.Handler, 3})
    out = DefconExample.sum_env(1, 2) |> Run.run(runner)
    assert %Freyja.RunOutcome{result: %Freyja.OkResult{value: 6}} = out
  end

  test "defconp with Writer accumulates outputs" do
    runner = Run.with_handlers(w: Writer.Handler)
    out = DefconExample.call_private(4, 5) |> Run.run(runner)

    assert %Freyja.RunOutcome{
             result: %Freyja.OkResult{value: 9},
             outputs: %{w: [4, 5]}
           } =
             out
  end

  test "defcon with Error and else handles divide by zero" do
    runner = Run.with_handlers(e: Error.Handler)
    out = DefconExample.safe_div(10, 0) |> Run.run(runner)
    assert %Freyja.RunOutcome{result: %Freyja.OkResult{value: :infty}} = out

    out2 = DefconExample.safe_div(10, 2) |> Run.run(runner)
    assert %Freyja.RunOutcome{result: %Freyja.OkResult{value: 5.0}} = out2
  end

  test "defcon composition: sum_and_log composes Reader and Writer and calls another defcon" do
    runner = Run.with_handlers(r: {Reader.Handler, 3}, w: Writer.Handler)

    out = DefconExample.sum_and_log(1, 2) |> Run.run(runner)

    assert %Freyja.RunOutcome{
             result: %Freyja.OkResult{value: 6},
             outputs: %{w: [{:sum, 6}]}
           } = out
  end

  test "defcon composition: sum_twice calls another defcon twice" do
    runner = Run.with_handlers(r: {Reader.Handler, 3})

    out = DefconExample.sum_twice(1, 2) |> Run.run(runner)

    # First sum_env: 1+2+3 = 6; second: 6+0+3 = 9
    assert %Freyja.RunOutcome{result: %Freyja.OkResult{value: 9}} = out
  end
end
