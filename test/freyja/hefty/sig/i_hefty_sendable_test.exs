defmodule Freyja.Hefty.Sig.IHeftySendableTest do
  use ExUnit.Case, async: true

  import Freyja.Freer.FreerBlock

  alias Freyja.Hefty
  alias Freyja.Hefty.Sig.IHeftySendable
  alias Freyja.Effects.Lift
  alias Freyja.Freer

  # Test struct that doesn't implement IHeftySendable
  defmodule NotAnEffect do
    defstruct [:data]
  end

  describe "send_to_hefty/1 - Hefty types" do
    test "Hefty.Pure returns unchanged" do
      pure = Hefty.pure(42)
      result = IHeftySendable.send_to_hefty(pure)

      assert result == pure
      assert %Hefty.Pure{val: 42} = result
    end

    test "Hefty.Impure returns unchanged" do
      impure = Hefty.send_hefty(:TestSig, %{}, %{})
      result = IHeftySendable.send_to_hefty(impure)

      assert result == impure
      assert %Hefty.Impure{sig: :TestSig} = result
    end
  end

  describe "send_to_hefty/1 - Freer types (auto-lift)" do
    test "Freer.Pure converts directly to Hefty.Pure (optimization)" do
      freer_pure = Freer.pure(42)
      result = IHeftySendable.send_to_hefty(freer_pure)

      # Optimization: Pure → Pure directly, no Lift needed
      assert %Hefty.Pure{val: 42} = result
    end

    test "Freer.Impure gets lifted" do
      alias Freyja.Effects.State

      freer_impure = State.get()
      result = IHeftySendable.send_to_hefty(freer_impure)

      # Should be wrapped in Lift
      assert %Hefty.Impure{
               sig: Lift,
               data: %Lift{computation: %Freer.Impure{sig: State}}
             } = result
    end

    test "lifted Freer can be bound" do
      alias Freyja.Effects.State

      freer =
        con do
          x <- State.get()
          _ <- State.put(x + 10)
          return(x)
        end

      hefty = IHeftySendable.send_to_hefty(freer)

      # Can bind in Hefty
      result = Hefty.bind(hefty, fn x -> Hefty.pure(x * 2) end)

      assert %Hefty.Impure{} = result
    end
  end

  describe "send_to_hefty/1 - unsupported types" do
    # Helper to bypass type checking for intentionally invalid inputs
    defp send_invalid(value), do: IHeftySendable.send_to_hefty(value)

    test "plain value raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, ~r/IHeftySendable not implemented/, fn ->
        send_invalid(42)
      end
    end

    test "plain map raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, ~r/IHeftySendable not implemented/, fn ->
        send_invalid(%{not: :a_computation})
      end
    end

    test "plain list raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, ~r/IHeftySendable not implemented/, fn ->
        send_invalid([1, 2, 3])
      end
    end

    test "arbitrary struct raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, ~r/IHeftySendable not implemented/, fn ->
        send_invalid(%NotAnEffect{data: :value})
      end
    end

    test "error message lists implemented types" do
      error =
        assert_raise Protocol.UndefinedError, fn ->
          send_invalid(:atom)
        end

      message = Exception.message(error)
      assert message =~ "IHeftySendable"
      assert message =~ "not implemented"
    end
  end

  describe "integration with Hefty.bind" do
    test "Hefty.bind auto-lifts Freer via catch-all clause" do
      alias Freyja.Effects.State

      # Bind Freer.Impure in Hefty context
      result = Hefty.bind(State.get(), fn x -> Hefty.pure(x) end)

      # Should auto-lift via protocol
      assert %Hefty.Impure{sig: Lift} = result
    end

    test "Hefty.bind auto-lifts Freer.Pure (optimized)" do
      freer_pure = Freer.pure(42)

      result = Hefty.bind(freer_pure, fn x -> Hefty.pure(x * 2) end)

      # Freer.Pure → Hefty.Pure (optimization in Lift)
      # Hefty.Pure.bind applies continuation immediately
      assert %Hefty.Pure{val: 84} = result
    end

    test "chain of auto-lifted Freer effects" do
      alias Freyja.Effects.State

      # Build chain of Freer effects
      result =
        State.get()
        |> Hefty.bind(fn x -> State.put(x + 1) end)
        |> Hefty.bind(fn _ -> State.get() end)
        |> Hefty.bind(fn x -> Hefty.pure(x) end)

      # Should all be lifted
      assert %Hefty.Impure{} = result
    end

    test "mixing Hefty and Freer via bind" do
      alias Freyja.Effects.State

      hefty_op = Hefty.send_hefty(:TestHefty, %{}, %{})
      freer_op = State.get()

      # Hefty then Freer
      result1 = Hefty.bind(hefty_op, fn _ -> freer_op end)
      assert %Hefty.Impure{sig: :TestHefty} = result1

      # Freer then Hefty (auto-lifts Freer)
      result2 = Hefty.bind(freer_op, fn _ -> hefty_op end)
      assert %Hefty.Impure{sig: Lift} = result2
    end
  end
end
