defmodule Freyja.Effects.StateTest do
  use ExUnit.Case

  require Logger

  import Freyja.Con

  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.Reader
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.Run

  # demonstrating composition with effects
  defcon multiply_store(a, b, c), [State] do
    r <- return(a * b * c)
    _ <- put(r)
    return(r)
  end

  defcon sum_log(a, b, c), [Writer] do
    r <- return(a + b + c)
    _ <- tell(r)
    return(r)
  end

  defcon calc(v), [Reader, Writer, State] do
    %{env: a} <- ask()
    b <- get()
    c <- return(v)
    product <- multiply_store(a, b, c)
    sum <- sum_log(a, b, c)
    return(%{product: product, sum: sum})
  end

  describe "simple state" do
    test "it does state stuff" do
      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          s: {State.Handler, 5},
          r: {Reader.Handler, %{env: 7}},
          w: {Writer.Handler, []}
        )

      outcome = Run.run(calc(10), runner)

      assert outcome.result == %{sum: 22, product: 350}
      assert outcome.outputs.s == 350
      assert outcome.outputs.w == [22]

      # Logger.error("#{__MODULE__}.outcome\n" <> inspect(outcome, pretty: true))
    end
  end
end
