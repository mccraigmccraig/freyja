defmodule Freyja.EffectLoggerTest do
  use ExUnit.Case

  require Logger

  import Freyja.Freer.FreerBlock

  alias Freyja.Freer
  alias Freyja.Freer.Impl
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Ops
  alias Freyja.Effects.EffectLogger
  alias Freyja.Effects.State
  alias Freyja.Run
  alias Freyja.Run.RunState

  # define constructors for a simple language with
  # - number
  # - error
  # - add operation
  # - subtract ooperation
  # - multiply operation
  # - divide operation
  defmodule NumbersGrammar do
    def number(a), do: {:number, a}
    def error(e), do: {:error, e}
    def add(a, b), do: {:add, a, b}
    def subtract(a, b), do: {:subtract, a, b}
    def multiply(a, b), do: {:multiply, a, b}
    def divide(a, b), do: {:divide, a, b}
  end

  defmodule Numbers do
    use Ops, constructors: NumbersGrammar
  end

  defmodule Numbers.Handler do
    alias Freyja.EffectLoggerTest.Numbers

    @behaviour Freyja.Freer.EffectHandler

    @impl Freyja.Freer.EffectHandler
    def handles?(%Impure{sig: sig, data: _data, q: _q}, _state) do
      sig == Numbers
    end

    @impl Freyja.Freer.EffectHandler
    def interpret(
          %Freer.Impure{sig: Numbers, data: u, q: q} = _computation,
          _handler_key,
          _state,
          %RunState{} = _run_state
        ) do
      next =
        case u do
          {:number, n} ->
            Impl.q_apply(q, n)

          {:also_number, n} ->
            Impl.q_apply(q, n)

          {:add, a, b} ->
            Impl.q_apply(q, a + b)

          {:subtract, a, b} ->
            Impl.q_apply(q, a - b)

          {:multiply, a, b} ->
            Impl.q_apply(q, a * b)

          {:divide, a, b} ->
            if b != 0 do
              Impl.q_apply(q, a / b)
            else
              Numbers.error("divide by zero #{a}/#{b}")
            end

          {:error, err} ->
            Freer.return({:error, err})
        end

      {next, nil}
    end

    def run(computation_or_builder, initial_state \\ :__default__) do
      Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, initial_state)
    end
  end

  describe "logger handler" do
    test "it can mix numbers with state" do
      fv =
        con [Numbers, State] do
          {:foo, a} <- get()
          b <- number(10)
          x <- return(12)
          _ <- put({:bar, a + b + x})
          c <- multiply(a, b)
          {:bar, d} <- get()
          subtract(d, c)
        end

      result =
        fv
        |> EffectLogger.Handler.run(EffectLogger.Log.new())
        |> Numbers.Handler.run()
        |> State.Handler.run({:foo, 12})
        |> Run.run()

      assert %Freyja.Run.RunOutcome{
               result: _final_val,
               outputs: %{
                 State.Handler => {:bar, 34},
                 EffectLogger.Handler => %Freyja.Effects.EffectLogger.Log{
                   stack: [],
                   queue: log_queue
                 }
               }
             } = result

      # stack is empty after preparing for resume
      #
      # log entries are fully deterministic
      assert log_queue == [
               %Freyja.Effects.EffectLogger.StepLogEntry{
                 value: {:foo, 12},
                 completed?: true,
                 effects_stack: [],
                 effects_queue: [
                   %Freyja.Effects.EffectLogger.EffectLogEntry{
                     sig: Freyja.Effects.State,
                     data: %Freyja.Effects.State.Get{}
                   }
                 ]
               },
               %Freyja.Effects.EffectLogger.StepLogEntry{
                 value: 10,
                 completed?: true,
                 effects_stack: [],
                 effects_queue: [
                   %Freyja.Effects.EffectLogger.EffectLogEntry{
                     sig: Freyja.EffectLoggerTest.Numbers,
                     data: {:number, 10}
                   }
                 ]
               },
               %Freyja.Effects.EffectLogger.StepLogEntry{
                 value: {:foo, 12},
                 completed?: true,
                 effects_stack: [],
                 effects_queue: [
                   %Freyja.Effects.EffectLogger.EffectLogEntry{
                     sig: Freyja.Effects.State,
                     data: %Freyja.Effects.State.Put{val: {:bar, 34}}
                   }
                 ]
               },
               %Freyja.Effects.EffectLogger.StepLogEntry{
                 value: 120,
                 completed?: true,
                 effects_stack: [],
                 effects_queue: [
                   %Freyja.Effects.EffectLogger.EffectLogEntry{
                     sig: Freyja.EffectLoggerTest.Numbers,
                     data: {:multiply, 12, 10}
                   }
                 ]
               },
               %Freyja.Effects.EffectLogger.StepLogEntry{
                 value: {:bar, 34},
                 completed?: true,
                 effects_stack: [],
                 effects_queue: [
                   %Freyja.Effects.EffectLogger.EffectLogEntry{
                     sig: Freyja.Effects.State,
                     data: %Freyja.Effects.State.Get{}
                   }
                 ]
               },
               %Freyja.Effects.EffectLogger.StepLogEntry{
                 value: -86,
                 completed?: true,
                 effects_stack: [],
                 effects_queue: [
                   %Freyja.Effects.EffectLogger.EffectLogEntry{
                     sig: Freyja.EffectLoggerTest.Numbers,
                     data: {:subtract, 34, 120}
                   }
                 ]
               }
             ]
    end
  end
end
