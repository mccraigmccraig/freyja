defmodule Freyja.Effects.ErrorTest do
  use ExUnit.Case

  require Logger

  import Freyja.Con

  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.Error
  alias Freyja.Effects.Writer
  alias Freyja.Effects.State
  alias Freyja.Run
  alias Freyja.RunOutcome
  alias Freyja.ErrorResult

  describe "throw/catch basics" do
    test "throw without catch propagates error" do
      fv =
        con [Error] do
          _ <- throw_fx(:oops)
          return(:unreachable)
        end

      runner = Run.with_handlers(e: Error.Handler)
      outcome = Run.run(fv, runner)

      assert %RunOutcome{result: %ErrorResult{error: :oops}} = outcome
    end
  end

  describe "recovery" do
    test "catch recovers from throw" do
      fv =
        con Error do
          res <-
            catch_fx(
              con Error do
                _ <- throw_fx(:bad)
                return(:nope)
              end,
              fn err -> return({:recovered, err}) end
            )

          return(res)
        end

      runner = Run.with_handlers(e: Error.Handler)
      outcome = Run.run(fv, runner)

      assert %Freyja.RunOutcome{
               result: %Freyja.OkResult{value: {:recovered, :bad}}
             } = outcome
    end
  end

  describe "catch and success" do
    test "catch passes through success" do
      fv =
        con Error do
          res <- catch_fx(return(42), fn _ -> return(0) end)
          return(res)
        end

      runner = Run.with_handlers(e: Error.Handler)
      outcome = Run.run(fv, runner)

      assert %Freyja.RunOutcome{result: %Freyja.OkResult{value: 42}} = outcome
    end
  end

  describe "composition with stateful Effects" do
    test "writer in successful computation is applied" do
      fv =
        con [Error, Writer] do
          tell(:from_outer_1)

          res <-
            catch_fx(
              con [Error, Writer] do
                tell(:from_inner)
                return(42)
              end,
              fn _ -> return(0) end
            )

          tell(:from_outer_2)

          return(res)
        end

      runner = Run.with_handlers(e: Error.Handler, w: Writer.Handler)
      outcome = Run.run(fv, runner)

      assert %Freyja.RunOutcome{
               result: %Freyja.OkResult{
                 value: 42
               },
               outputs: %{w: [:from_outer_1, :from_inner, :from_outer_2]}
             } = outcome
    end

    test "writer in throwing computation is discarded" do
      fv =
        con [Error, Writer] do
          tell(:from_outer_1)

          res <-
            catch_fx(
              con [Error, Writer] do
                tell(:from_inner)
                throw_fx(:bad)
                return(:nope)
              end,
              fn _err -> throw_fx(:also_bad) end
            )

          tell(:from_outer_2)

          return(res)
        end

      runner = Run.with_handlers(e: Error.Handler, w: Writer.Handler)
      outcome = Run.run(fv, runner)

      assert %Freyja.RunOutcome{
               result: %Freyja.ErrorResult{error: :also_bad},
               outputs: %{w: [:from_outer_1]}
             } = outcome
    end

    test "writer in recovered computation is applied" do
      fv =
        con [Error, Writer] do
          tell(:from_outer_1)

          res <-
            catch_fx(
              con [Error, Writer] do
                tell(:from_inner)
                throw_fx(:bad)
                return(:nope)
              end,
              fn err -> return({:recovered, err}) end
            )

          tell(:from_outer_2)

          return(res)
        end

      runner = Run.with_handlers(e: Error.Handler, w: Writer.Handler)
      outcome = Run.run(fv, runner)

      assert %Freyja.RunOutcome{
               result: %Freyja.OkResult{value: {:recovered, :bad}},
               outputs: %{w: [:from_outer_1, :from_inner, :from_outer_2]}
             } = outcome
    end

    test "state in successful computation is applied" do
      fv =
        con [Error, State] do
          put(5)

          res <-
            catch_fx(
              con [Error, State] do
                a <- get()
                put(a + 5)
                return(42)
              end,
              fn _ -> return(0) end
            )

          b <- get()
          put(b + 5)

          return(res)
        end

      runner = Run.with_handlers(e: Error.Handler, s: State.Handler)
      outcome = Run.run(fv, runner)

      assert %Freyja.RunOutcome{
               result: %Freyja.OkResult{
                 value: 42
               },
               outputs: %{s: 15}
             } = outcome
    end

    test "state in failed computation is discarded" do
      fv =
        con [Error, State] do
          put(5)

          res <-
            catch_fx(
              con [Error, State] do
                a <- get()
                put(a + 5)
                throw_fx(:bad)
                return(:nope)
              end,
              fn _err -> throw_fx(:also_bad) end
            )

          b <- get()
          put(b + 5)

          return(res)
        end

      runner = Run.with_handlers(e: Error.Handler, s: State.Handler)
      outcome = Run.run(fv, runner)

      assert %Freyja.RunOutcome{
               result: %Freyja.ErrorResult{error: :also_bad},
               outputs: %{s: 5}
             } = outcome
    end

    test "state in reocvered computation is applied" do
      fv =
        con [Error, State] do
          put(5)

          res <-
            catch_fx(
              con [Error, State] do
                a <- get()
                put(a + 5)
                throw_fx(:bad)
                return(:nope)
              end,
              fn err -> return({:recovered, err}) end
            )

          b <- get()
          c <- return(b + 5)
          put(c)

          return(res)
        end

      runner =
        Run.with_handlers(
          l: EffectLogger.Handler,
          e: Error.Handler,
          s: State.Handler
        )

      outcome = Run.run(fv, runner)

      assert %Freyja.RunOutcome{
               result: %Freyja.OkResult{value: {:recovered, :bad}},
               outputs: %{s: 15}
             } = outcome

      # Logger.error("#{__MODULE__}.outcome #{inspect(outcome, pretty: true)}")
    end
  end
end
