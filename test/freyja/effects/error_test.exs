defmodule Freyja.Effects.ErrorTest do
  use ExUnit.Case

  require Logger

  import Freyja.HeftyMacro

  alias Freyja.Hefty
  alias Freyja.Effects.Catch
  alias Freyja.Effects.Lift
  alias Freyja.Effects.Throw
  alias Freyja.Effects.Throw.Handler, as: ThrowHandler
  alias Freyja.Hefty.Run, as: HeftyRun
  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.Writer
  alias Freyja.Effects.State
  alias Freyja.RunOutcome

  describe "throw/catch basics" do
    test "throw without catch propagates error" do
      fv =
        hefty do
          _ <- Lift.lift(Throw.throw_error(:oops))
          return(:unreachable)
        end

      outcome = HeftyRun.run(fv, [Lift.Algebra], [ThrowHandler])

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
                _ <- Lift.lift(Throw.throw_error(:bad))
                return(:nope)
              end,
              fn _err -> Hefty.pure({:recovered, :bad}) end
            )

          return(res)
        end

      outcome =
        HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [ThrowHandler])

      assert %Freyja.RunOutcome{
               result: {:ok, {:recovered, :bad}}
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

      outcome =
        HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [ThrowHandler])

      assert %Freyja.RunOutcome{result: {:ok, 42}} = outcome
    end
  end

  describe "composition with stateful Effects" do
    test "writer in successful computation is applied" do
      fv =
        hefty do
          _ <- Lift.lift(Writer.tell(:from_outer_1))

          res <-
            Catch.catch_hefty(
              hefty do
                _ <- Lift.lift(Writer.tell(:from_inner))
                return(42)
              end,
              fn _err -> Hefty.pure(0) end
            )

          _ <- Lift.lift(Writer.tell(:from_outer_2))

          return(res)
        end

      outcome =
        HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [
          ThrowHandler,
          Writer.Handler,
        ])

      assert %Freyja.RunOutcome{
               result: {:ok, 42},
               outputs: %{Writer.Handler => [:from_outer_2, :from_inner, :from_outer_1]}
             } = outcome
    end

    test "writer in throwing computation is PRESERVED (non-transactional)" do
      fv =
        hefty do
          _ <- Lift.lift(Writer.tell(:from_outer_1))

          res <-
            Catch.catch_hefty(
              hefty do
                _ <- Lift.lift(Writer.tell(:from_inner))
                _ <- Lift.lift(Throw.throw_error(:bad))
                return(:nope)
              end,
              fn _err ->
                hefty do
                  _ <- Lift.lift(Throw.throw_error(:also_bad))
                  return(:unreachable)
                end
              end
            )

          _ <- Lift.lift(Writer.tell(:from_outer_2))

          return(res)
        end

      outcome =
        HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [
          ThrowHandler,
          Writer.Handler,
        ])

      # Hefty Catch uses non-transactional semantics - state changes persist even on error
      assert %Freyja.RunOutcome{
               result: {:error, :also_bad},
               outputs: %{Writer.Handler => [:from_inner, :from_outer_1]}
             } = outcome
    end

    test "writer in recovered computation is applied" do
      fv =
        hefty do
          _ <- Lift.lift(Writer.tell(:from_outer_1))

          res <-
            Catch.catch_hefty(
              hefty do
                _ <- Lift.lift(Writer.tell(:from_inner))
                _ <- Lift.lift(Throw.throw_error(:bad))
                return(:nope)
              end,
              fn _err -> Hefty.pure({:recovered, :bad}) end
            )

          _ <- Lift.lift(Writer.tell(:from_outer_2))

          return(res)
        end

      outcome =
        HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [
          ThrowHandler,
          Writer.Handler,
        ])

      assert %Freyja.RunOutcome{
               result: {:ok, {:recovered, :bad}},
               outputs: %{Writer.Handler => [:from_outer_2, :from_inner, :from_outer_1]}
             } = outcome
    end

    test "state in successful computation is applied" do
      fv =
        hefty do
          _ <- Lift.lift(State.put(5))

          res <-
            Catch.catch_hefty(
              hefty do
                a <- Lift.lift(State.get())
                _ <- Lift.lift(State.put(a + 5))
                return(42)
              end,
              fn _err -> Hefty.pure(0) end
            )

          b <- Lift.lift(State.get())
          _ <- Lift.lift(State.put(b + 5))

          return(res)
        end

      outcome =
        HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [
          State.Handler,
          ThrowHandler,
        ])

      assert %Freyja.RunOutcome{
               result: {:ok, 42},
               outputs: %{State.Handler => 15}
             } = outcome
    end

    test "state in failed computation is PRESERVED (non-transactional)" do
      fv =
        hefty do
          _ <- Lift.lift(State.put(5))

          res <-
            Catch.catch_hefty(
              hefty do
                a <- Lift.lift(State.get())
                _ <- Lift.lift(State.put(a + 5))
                _ <- Lift.lift(Throw.throw_error(:bad))
                return(:nope)
              end,
              fn _err ->
                hefty do
                  _ <- Lift.lift(Throw.throw_error(:also_bad))
                  return(:unreachable)
                end
              end
            )

          b <- Lift.lift(State.get())
          _ <- Lift.lift(State.put(b + 5))

          return(res)
        end

      outcome =
        HeftyRun.run(fv, [Catch.Algebra, Lift.Algebra], [
          State.Handler,
          ThrowHandler,
        ])

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
          _ <- Lift.lift(State.put(5))

          res <-
            Catch.catch_hefty(
              hefty do
                a <- Lift.lift(State.get())
                _ <- Lift.lift(State.put(a + 5))
                _ <- Lift.lift(Throw.throw_error(:bad))
                return(:nope)
              end,
              fn _err -> Hefty.pure({:recovered, :bad}) end
            )

          b <- Lift.lift(State.get())
          c <- return(b + 5)
          _ <- Lift.lift(State.put(c))

          return(res)
        end

      outcome =
        HeftyRun.run(
          fv,
          [Catch.Algebra, Lift.Algebra],
          [EffectLogger.Handler, State.Handler, ThrowHandler]
        )

      assert %Freyja.RunOutcome{
               result: {:ok, {:recovered, :bad}},
               outputs: %{State.Handler => 15}
             } = outcome

      # Logger.error("#{__MODULE__}.outcome #{inspect(outcome, pretty: true)}")
    end
  end
end
