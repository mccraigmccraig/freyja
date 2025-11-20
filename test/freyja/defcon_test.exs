defmodule Freyja.DefconTest do
  use ExUnit.Case

  alias Freyja.Effects.Reader
  alias Freyja.Effects.Writer
  alias Freyja.Effects.Throw
  alias Freyja.Effects.Catch
  alias Freyja.Effects.Lift
  alias Freyja.Run
  alias Freyja.Hefty

  defmodule DefconExample do
    import Freyja.Con
    import Freyja.HeftyMacro

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

    # Migrated from defcon...catch to defhefty...catch
    defhefty safe_div(a, b) do
      if b == 0 do
        Lift.lift(Throw.throw_error(:zero))
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
    out = Run.run(DefconExample.sum_env(1, 2), [Reader.Handler], %{Reader.Handler => 3})
    assert %Freyja.RunOutcome{result: 6} = out
  end

  test "defconp with Writer accumulates outputs" do
    out = Run.run(DefconExample.call_private(4, 5), [Writer.Handler])

    assert %Freyja.RunOutcome{
             result: 9,
             outputs: %{Writer.Handler => [5, 4]}
           } =
             out
  end

  test "defhefty with Throw and catch clause handles divide by zero" do
    algebras = [Catch.Algebra, Lift.Algebra]
    handlers = [Throw.Handler]

    out = Hefty.Run.run(DefconExample.safe_div(10, 0), algebras, handlers)
    assert %Freyja.RunOutcome{result: {:ok, :infty}} = out

    out2 = Hefty.Run.run(DefconExample.safe_div(10, 2), algebras, handlers)
    assert %Freyja.RunOutcome{result: {:ok, 5.0}} = out2
  end

  test "defcon composition: sum_and_log composes Reader and Writer and calls another defcon" do
    out = Run.run(
      DefconExample.sum_and_log(1, 2),
      [Reader.Handler, Writer.Handler],
      %{Reader.Handler => 3}
    )

    assert %Freyja.RunOutcome{
             result: 6,
             outputs: %{Writer.Handler => [{:sum, 6}]}
           } = out
  end

  test "defcon composition: sum_twice calls another defcon twice" do
    out = Run.run(DefconExample.sum_twice(1, 2), [Reader.Handler], %{Reader.Handler => 3})

    # First sum_env: 1+2+3 = 6; second: 6+0+3 = 9
    assert %Freyja.RunOutcome{result: 9} = out
  end
end
