defmodule Freyja.Effects.ErrorTest do
  use ExUnit.Case

  require Logger

  import Freyja.HeftyMacro

  alias Freyja.Hefty
  alias Freyja.Effects.Catch
  alias Freyja.Effects.Lift
  alias Freyja.Effects.Error
  alias Freyja.Effects.Error.Handler, as: ErrorHandler
  alias Freyja.Hefty.Run, as: HeftyRun
  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.Writer
  alias Freyja.Effects.State
  alias Freyja.RunOutcome

  describe "throw/catch basics" do
    test "throw without catch propagates error" do
      fv =
        hefty do
          Lift.lift(Error.throw_error(:oops))
          return(:unreachable)
        end

      outcome = HeftyRun.run(fv, [Lift.Algebra], [ErrorHandler])

      assert %RunOutcome{result: {:error, :oops}} = outcome
    end
  end

  describe "recovery" do
    test "catch recovers from throw" do
      fv =
        hefty do
          res <-
            Catch.catch_hefty(
              hefty do
                Lift.lift(Error.throw_error(:bad))
                return(:nope)
              end,
              fn _err -> Hefty.pure({:recovered, :bad}) end
            )

          return(res)
        end

      outcome = HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [ErrorHandler, Catch.RunCatchingHandler])

      assert %Freyja.RunOutcome{
               result: {:recovered, :bad}
             } = outcome
    end
  end

  describe "catch and success" do
    test "catch passes through success" do
      fv =
        hefty do
          res <- Catch.catch_hefty(Hefty.pure(42), fn _err -> Hefty.pure(0) end)
          return(res)
        end

      outcome = HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [ErrorHandler, Catch.RunCatchingHandler])

      assert %Freyja.RunOutcome{result: 42} = outcome
    end
  end

  describe "composition with stateful Effects" do
    test "writer in successful computation is applied" do
      fv =
        hefty do
          Lift.lift(Writer.tell(:from_outer_1))

          res <-
            Catch.catch_hefty(
              hefty do
                Lift.lift(Writer.tell(:from_inner))
                return(42)
              end,
              fn _err -> Hefty.pure(0) end
            )

          Lift.lift(Writer.tell(:from_outer_2))

          return(res)
        end

      outcome = HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [ErrorHandler, Writer.Handler, Catch.RunCatchingHandler])

      assert %Freyja.RunOutcome{
               result: 42,
               outputs: %{Writer.Handler => [:from_outer_2, :from_inner, :from_outer_1]}
             } = outcome
    end

    test "writer in throwing computation is PRESERVED (non-transactional)" do
      fv =
        hefty do
          Lift.lift(Writer.tell(:from_outer_1))

          res <-
            Catch.catch_hefty(
              hefty do
                Lift.lift(Writer.tell(:from_inner))
                Lift.lift(Error.throw_error(:bad))
                return(:nope)
              end,
              fn _err ->
                hefty do
                  Lift.lift(Error.throw_error(:also_bad))
                end
              end
            )

          Lift.lift(Writer.tell(:from_outer_2))

          return(res)
        end

      outcome = HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [ErrorHandler, Writer.Handler, Catch.RunCatchingHandler])

      # Hefty Catch uses non-transactional semantics - state changes persist even on error
      assert %Freyja.RunOutcome{
               result: {:error, :also_bad},
               outputs: %{Writer.Handler => [:from_inner, :from_outer_1]}
             } = outcome
    end

    test "writer in recovered computation is applied" do
      fv =
        hefty do
          Lift.lift(Writer.tell(:from_outer_1))

          res <-
            Catch.catch_hefty(
              hefty do
                Lift.lift(Writer.tell(:from_inner))
                Lift.lift(Error.throw_error(:bad))
                return(:nope)
              end,
              fn _err -> Hefty.pure({:recovered, :bad}) end
            )

          Lift.lift(Writer.tell(:from_outer_2))

          return(res)
        end

      outcome = HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [ErrorHandler, Writer.Handler, Catch.RunCatchingHandler])

      assert %Freyja.RunOutcome{
               result: {:recovered, :bad},
               outputs: %{Writer.Handler => [:from_outer_2, :from_inner, :from_outer_1]}
             } = outcome
    end

    test "state in successful computation is applied" do
      fv =
        hefty do
          Lift.lift(State.put(5))

          res <-
            Catch.catch_hefty(
              hefty do
                a <- Lift.lift(State.get())
                Lift.lift(State.put(a + 5))
                return(42)
              end,
              fn _err -> Hefty.pure(0) end
            )

          b <- Lift.lift(State.get())
          Lift.lift(State.put(b + 5))

          return(res)
        end

      outcome = HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [State.Handler, ErrorHandler, Catch.RunCatchingHandler])

      assert %Freyja.RunOutcome{
               result: 42,
               outputs: %{State.Handler => 15}
             } = outcome
    end

    test "state in failed computation is PRESERVED (non-transactional)" do
      fv =
        hefty do
          Lift.lift(State.put(5))

          res <-
            Catch.catch_hefty(
              hefty do
                a <- Lift.lift(State.get())
                Lift.lift(State.put(a + 5))
                Lift.lift(Error.throw_error(:bad))
                return(:nope)
              end,
              fn _err ->
                hefty do
                  Lift.lift(Error.throw_error(:also_bad))
                end
              end
            )

          b <- Lift.lift(State.get())
          Lift.lift(State.put(b + 5))

          return(res)
        end

      outcome = HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [State.Handler, ErrorHandler, Catch.RunCatchingHandler])

      # Hefty Catch uses non-transactional semantics - state changes persist even on error
      # Initial state: nil -> put(5) = 5 -> put(10) in try block = 10
      assert %Freyja.RunOutcome{
               result: {:error, :also_bad},
               outputs: %{State.Handler => 10}
             } = outcome
    end

    test "state in reocvered computation is applied" do
      fv =
        hefty do
          Lift.lift(State.put(5))

          res <-
            Catch.catch_hefty(
              hefty do
                a <- Lift.lift(State.get())
                Lift.lift(State.put(a + 5))
                Lift.lift(Error.throw_error(:bad))
                return(:nope)
              end,
              fn _err -> Hefty.pure({:recovered, :bad}) end
            )

          b <- Lift.lift(State.get())
          c <- return(b + 5)
          Lift.lift(State.put(c))

          return(res)
        end

      outcome = HeftyRun.run(
        fv,
        [Catch.Algebra, Lift.Algebra],
        [EffectLogger.Handler, State.Handler, ErrorHandler, Catch.RunCatchingHandler]
      )

      assert %Freyja.RunOutcome{
               result: {:recovered, :bad},
               outputs: %{State.Handler => 15}
             } = outcome

      # Logger.error("#{__MODULE__}.outcome #{inspect(outcome, pretty: true)}")
    end
  end
end
