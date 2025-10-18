defmodule Freyja.FreerTest do
  use ExUnit.Case

  require Logger
  alias Freyja.Effects.Reader
  alias Freyja.Effects.ReaderHandler
  alias Freyja.Effects.Writer
  alias Freyja.Effects.WriterHandler
  alias Freyja.Effects.State
  alias Freyja.Effects.State
  alias Freyja.Freer
  alias Freyja.Freer.{Pure, Impure}
  alias Freyja.Freer.Ops
  import Freyja.Con

  defp unwrap(v) do
    case v do
      %Freyja.RunOutcome{result: res} -> unwrap(res)
      %Freyja.OkResult{value: inner} -> unwrap(inner)
      other -> other
    end
  end

  describe "pure" do
    test "it wraps a value" do
      assert %Pure{val: 10} === Freer.pure(10)
    end
  end

  describe "send" do
    test "it wraps values into the Freer Monad" do
      assert %Impure{sig: EffectMod, data: :val, q: [&Freer.pure/1]} ==
               Freer.send_effect(:val, EffectMod)
    end
  end

  describe "return" do
    test "it returns a value" do
      assert %Pure{val: 10} === Freer.return(10)
    end
  end

  describe "bind" do
    test "it binds a value" do
      assert %Impure{sig: EffectMod, data: 10, q: [pure_f, step_f]} =
               Freer.send_effect(10, EffectMod)
               |> Freer.bind(fn x -> Freer.return(2 * x) end)

      assert %Pure{val: 10} == pure_f.(10)
      assert %Pure{val: 20} == step_f.(10)
    end

    test "it binds repeatedly with pure expressions" do
      assert %Impure{sig: EffectMod, data: 10, q: [pure_f, step_1_f, step_2_f]} =
               Freer.send_effect(10, EffectMod)
               |> Freer.bind(fn x -> Freer.return(2 * x) end)
               |> Freer.bind(fn x -> Freer.return(5 + x) end)

      assert %Pure{val: 10} = pure_f.(10)
      assert %Pure{val: 20} = step_1_f.(10)
      assert %Pure{val: 25} = step_2_f.(20)
    end

    test "it binds repeatedly with impure expressions" do
      assert %Impure{sig: EffectMod, data: 10, q: [step_1, step_2, step_3]} =
               Freer.send_effect(10, EffectMod)
               |> Freer.bind(fn x ->
                 x |> Freer.send_effect(EffectMod) |> Freer.bind(fn y -> Freer.return(2 * y) end)
               end)
               |> Freer.bind(fn x ->
                 x |> Freer.send_effect(EffectMod) |> Freer.bind(fn y -> Freer.return(5 + y) end)
               end)

      # trace the steps manually, feeding values from one into the next - this
      # is exactly what an interpreter for the identity effect would do
      pure = &Freer.pure/1
      assert %Pure{val: 10} = step_1.(10)
      assert %Impure{sig: EffectMod, data: 10, q: [^pure, step_2_2]} = step_2.(10)
      assert %Pure{val: 20} = step_2_2.(10)
      assert %Impure{sig: EffectMod, data: 20, q: [^pure, step_3_2]} = step_3.(20)
      assert %Pure{val: 25} = step_3_2.(20)
    end
  end

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

  # interpret the Numbers langauge with ret + handle functions
  #
  # ret and handle must return Freer structs
  #
  # - ret : wrap a plain value in a Freer<Numbers>
  # - handle : interpret a Numbers statement, either
  #  passing a plain value on to the continuation, or
  #  short-circuit returning a Freer<Numbers>
  defmodule InterpretNumbers do
    # wrap a value in a Numbers structure
    def ret(n), do: Freer.return(Freyja.RunOutcome.ensure(n))

    # interpret a Numbers structure and pass a value on to
    # the continuation. The continuiation will return a Freer,
    # so handle must return a Freer too if it doesn't call
    # the continuation
    def handle({:number, n}, k), do: k.(n)
    def handle({:also_number, n}, k), do: k.(n)
    def handle({:add, a, b}, k), do: k.(a + b)
    def handle({:subtract, a, b}, k), do: k.(a - b)
    def handle({:multiply, a, b}, k), do: k.(a * b)

    def handle({:divide, a, b}, k) do
      if b != 0 do
        k.(a / b)
      else
        Freer.return(Freyja.RunOutcome.ok({:error, "divide by zero: #{a}/#{b}"}))
      end
    end

    def handle({:error, err}, _f), do: Freer.return({:error, err})
  end

  def run_numbers(fv) do
    fv
    |> Freyja.Freer.Impl.handle_relay(
      [Numbers],
      &InterpretNumbers.ret/1,
      &InterpretNumbers.handle/2
    )
  end

  # Reader and Writer effects have been moved to their own modules
  # Freyja.Reader and Freyja.Writer

  def run_reader(fv, reader_val) do
    ReaderHandler.interpret_reader(fv, reader_val)
  end

  def run_writer(fv) do
    WriterHandler.interpret_writer(fv)
  end

  # State effect has been moved to its own module Freyja.State

  describe "q_apply" do
  end

  describe "q_comp" do
  end

  # now take the interpreter for a run

  describe "interpret" do
    test "it interprets a pure value" do
      fv = Freer.pure(10)

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_numbers() |> Freer.run()

      assert v == 10
      assert out == %{}
    end

    test "it interprets a short sequence of operations" do
      fv =
        Numbers.number(10)
        |> Freer.bind(fn x -> Numbers.multiply(x, 10) end)

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_numbers() |> Freer.run()

      assert v == 100
      assert out == %{}
    end

    test "it interprets a more complex composition of operations" do
      fv =
        Numbers.number(10)
        |> Freer.bind(fn x ->
          Numbers.number(2) |> Freer.bind(fn y -> Freer.return(x + y) end)
        end)
        |> Freer.bind(fn x ->
          Numbers.number(5) |> Freer.bind(fn z -> Freer.return(x * z) end)
        end)

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_numbers() |> Freer.run()

      assert v == 60
      assert out == %{}
    end

    test "it interprets a slightly longer sequence of operations" do
      fv =
        Numbers.number(10)
        |> Freer.bind(fn a -> Numbers.multiply(a, 5) end)
        |> Freer.bind(fn b -> Numbers.add(b, 30) end)
        |> Freer.bind(fn c -> Numbers.divide(c, 20) end)
        |> Freer.bind(fn d -> Numbers.subtract(d, 8) end)

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_numbers() |> Freer.run()

      assert v == -4.0
      assert out == %{}
    end

    test "it interprets nested operations" do
      fv =
        Numbers.number(10)
        |> Freer.bind(fn a ->
          Numbers.number(20)
          |> Freer.bind(fn b ->
            Numbers.number(5)
            |> Freer.bind(fn c ->
              Numbers.multiply(a, b)
              |> Freer.bind(fn d ->
                Numbers.add(c, d)
              end)
            end)
          end)
        end)

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_numbers() |> Freer.run()

      assert v == 205
      assert out == %{}
    end

    test "it short circuits on divide by zero" do
      fv =
        Numbers.number(10)
        |> Freer.bind(fn x -> Numbers.multiply(x, 10) end)
        |> Freer.bind(fn y -> Numbers.divide(y, 0) end)
        |> Freer.bind(fn z -> Numbers.add(z, 10) end)

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: res}, outputs: out} =
        fv |> run_numbers() |> Freer.run()

      assert {:error, err} = res
      assert err =~ ~r/divide by zero/
      assert out == %{}
    end
  end

  describe "con" do
    test "it provides a nice bind syntax sugar" do
      fv =
        con Numbers do
          a <- number(10)
          b <- number(1000)
          c <- add(a, b)
          d <- multiply(a, b)
          subtract(d, c)
        end

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_numbers() |> Freer.run()

      assert v == 8990
      assert out == %{}
    end

    test "it can run a reader" do
      fv =
        con Reader do
          a <- Freer.return(10)
          b <- get()
          Freer.return(a + b)
        end

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_reader(12) |> Freer.run()

      assert v == 22
      assert out == %{}
    end

    test "it can run a reader and a writer" do
      fv =
        con [Reader, Writer] do
          a <- Freer.return(10)
          b <- get()
          _c <- put(a + b)
          _d <- put(a * b)
          Freer.return(2 * (a + b))
        end

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_writer() |> run_reader(12) |> Freer.run()

      assert v == 44
      assert out.writer == [22, 120]

      # the order of the handlers should not matter for this combination of effects
      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v2}, outputs: out2} =
        fv |> run_reader(12) |> run_writer() |> Freer.run()

      assert v2 == v
      assert out2.writer == out.writer
    end

    test "it can mix numbers with a reader" do
      fv =
        con [Numbers, Reader] do
          a <- number(10)
          b <- get()
          c <- add(a, b)
          d <- multiply(a, b)
          subtract(d, c)
        end

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_numbers() |> run_reader(12) |> Freer.run()

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v2_val}, outputs: out2} =
        fv |> run_reader(12) |> run_numbers() |> Freer.run()

      assert v == 98
      assert unwrap(v2_val) == 98
      assert out == %{}
      assert out2 == %{}
    end

    test "it can mix numbers with a reader and a writer" do
      fv =
        con [Numbers, Reader, Writer] do
          a <- number(10)
          put(a)
          b <- get()
          put(b)
          c <- add(a, b)
          put(c)
          d <- multiply(a, b)
          put(d) |> Freer.bind(fn _ -> subtract(d, c) end)
        end

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_numbers() |> run_reader(12) |> run_writer() |> Freer.run()

      assert v == 98
      assert out.writer == [10, 12, 22, 120]

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v3_val}, outputs: out3} =
        fv |> run_writer |> run_reader(12) |> run_numbers() |> Freer.run()

      assert unwrap(v3_val) == 98
      assert out3.writer == [10, 12, 22, 120]
    end

    test "it can mix numbers with the state interpretation of Reader+Writer" do
      fv =
        con [Numbers, Reader, Writer] do
          a <- get()
          b <- number(10)
          put(a + b)
          c <- multiply(a, b)
          d <- get()
          subtract(d, c)
        end

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: v}, outputs: out} =
        fv |> run_numbers() |> State.interpret_state(12) |> Freer.run()

      assert v == -98
      assert out.state == 22
    end

    test "it short circuits" do
      fv =
        con Numbers do
          a <- number(10)
          b <- number(1000)
          c <- divide(a, 0)
          multiply(b, c)
        end

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: res}, outputs: out} =
        fv |> run_numbers() |> Freer.run()

      assert {:error, msg} = res
      assert out == %{}
      assert msg =~ ~r/divide by zero/
    end

    test "it short circuits Numbes in combination with other effects" do
      fv =
        con [Numbers, Reader, Writer] do
          a <- get()
          b <- number(1000)
          c <- divide(a, 0)
          put(c)
          multiply(b, c)
        end

      %Freyja.RunOutcome{result: %Freyja.OkResult{value: res2}, outputs: out2} =
        fv |> run_numbers() |> State.interpret_state(10) |> Freer.run()

      assert {:error, msg2} = res2
      assert out2.state == 10
      assert msg2 =~ ~r/divide by zero/
    end
  end
end
