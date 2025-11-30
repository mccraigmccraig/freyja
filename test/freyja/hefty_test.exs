defmodule Freyja.HeftyTest do
  use ExUnit.Case, async: true

  alias Freyja.Hefty
  alias Freyja.Hefty.Pure
  alias Freyja.Hefty.Impure
  alias Freyja.Effects.State
  alias Freyja.Run

  doctest Freyja.Hefty

  describe "pure/1" do
    test "creates Pure node with value" do
      assert %Pure{val: 42} = Hefty.pure(42)
      assert %Pure{val: "hello"} = Hefty.pure("hello")
      assert %Pure{val: [1, 2, 3]} = Hefty.pure([1, 2, 3])
    end

    test "return/1 is alias for pure/1" do
      assert Hefty.return(42) == Hefty.pure(42)
    end
  end

  describe "send_hefty/3" do
    test "creates Impure node with signature and operation" do
      result = Hefty.send_hefty(:TestSig, %{op: :test}, %{})

      assert %Impure{
               sig: :TestSig,
               data: %{op: :test},
               psi: %{},
               k: k
             } = result

      # Continuation should be identity (pure)
      assert k.(42) == Hefty.pure(42)
    end

    test "creates Impure node with computation parameters" do
      comp1 = Hefty.pure(1)
      comp2 = Hefty.pure(2)

      result =
        Hefty.send_hefty(
          :Catch,
          %{},
          %{try: comp1, catch: comp2}
        )

      assert %Impure{
               sig: :Catch,
               psi: %{try: ^comp1, catch: ^comp2}
             } = result
    end
  end

  describe "bind/2 - monad laws" do
    test "left identity: pure(x) >>= f ≡ f(x)" do
      x = 42
      f = fn n -> Hefty.pure(n + 1) end

      lhs = Hefty.bind(Hefty.pure(x), f)
      rhs = f.(x)

      assert lhs == rhs
    end

    test "right identity: m >>= pure ≡ m" do
      m = Hefty.pure(42)

      lhs = Hefty.bind(m, &Hefty.pure/1)
      rhs = m

      assert lhs == rhs
    end

    test "associativity: (m >>= f) >>= g ≡ m >>= (λx -> f(x) >>= g)" do
      m = Hefty.pure(42)
      f = fn n -> Hefty.pure(n + 1) end
      g = fn n -> Hefty.pure(n * 2) end

      lhs = Hefty.bind(Hefty.bind(m, f), g)
      rhs = Hefty.bind(m, fn x -> Hefty.bind(f.(x), g) end)

      # Both should produce Pure{val: 86}
      assert lhs == rhs
      assert %Pure{val: 86} = lhs
    end
  end

  describe "bind/2 with Pure" do
    test "immediately applies continuation to value" do
      result = Hefty.bind(Hefty.pure(5), fn x -> Hefty.pure(x * 2) end)

      assert %Pure{val: 10} = result
    end

    test "chains multiple binds" do
      result =
        Hefty.pure(5)
        |> Hefty.bind(fn x -> Hefty.pure(x + 1) end)
        |> Hefty.bind(fn x -> Hefty.pure(x * 2) end)
        |> Hefty.bind(fn x -> Hefty.pure(x - 3) end)

      assert %Pure{val: 9} = result
    end

    test "continuation can return Impure" do
      result =
        Hefty.bind(Hefty.pure(5), fn x ->
          Hefty.send_hefty(:Test, %{val: x}, %{})
        end)

      assert %Impure{data: %{val: 5}} = result
    end
  end

  describe "bind/2 with Impure" do
    test "composes continuations" do
      op = Hefty.send_hefty(:Test, %{}, %{})
      result = Hefty.bind(op, fn x -> Hefty.pure(x + 1) end)

      assert %Impure{
               sig: :Test,
               k: composed_k
             } = result

      # The composed continuation should add 1
      assert composed_k.(5) == Hefty.pure(6)
    end

    test "composes multiple continuations" do
      op = Hefty.send_hefty(:Test, %{}, %{})

      result =
        op
        |> Hefty.bind(fn x -> Hefty.pure(x + 1) end)
        |> Hefty.bind(fn x -> Hefty.pure(x * 2) end)

      assert %Impure{k: k} = result

      # Should apply: (5 + 1) * 2 = 12
      assert k.(5) == Hefty.pure(12)
    end

    test "preserves sig, data, and psi" do
      comp1 = Hefty.pure(1)
      comp2 = Hefty.pure(2)

      op =
        Hefty.send_hefty(
          :Catch,
          %{type: :test},
          %{try: comp1, catch: comp2}
        )

      result = Hefty.bind(op, fn x -> Hefty.pure(x + 1) end)

      assert %Impure{
               sig: :Catch,
               data: %{type: :test},
               psi: %{try: ^comp1, catch: ^comp2}
             } = result
    end

    test "continuation can return Impure, creating nested structure" do
      op1 = Hefty.send_hefty(:Op1, %{}, %{})

      result =
        Hefty.bind(op1, fn x ->
          Hefty.send_hefty(:Op2, %{val: x}, %{})
        end)

      assert %Impure{sig: :Op1, k: k} = result

      # Calling continuation should give Op2
      assert %Impure{sig: :Op2, data: %{val: 5}} = k.(5)
    end
  end

  describe "bind/2 - complex scenarios" do
    test "binding over operation with computation parameters" do
      # Create a Catch-like operation with two forks
      try_comp = Hefty.pure(42)
      catch_comp = Hefty.pure(0)

      catch_op =
        Hefty.send_hefty(
          :Catch,
          %{},
          %{try: try_comp, catch: catch_comp}
        )

      # Bind a continuation that processes the result
      result = Hefty.bind(catch_op, fn x -> Hefty.pure(x * 2) end)

      # Should preserve the operation structure
      assert %Impure{
               sig: :Catch,
               psi: %{try: ^try_comp, catch: ^catch_comp},
               k: k
             } = result

      # Continuation should double the value
      assert k.(21) == Hefty.pure(42)
    end

    test "deeply nested bind chain" do
      # Simulate a chain of operations
      result =
        Hefty.send_hefty(:Op1, %{}, %{})
        |> Hefty.bind(fn _ -> Hefty.send_hefty(:Op2, %{}, %{}) end)
        |> Hefty.bind(fn _ -> Hefty.send_hefty(:Op3, %{}, %{}) end)
        |> Hefty.bind(fn x -> Hefty.pure(x) end)

      # Should be Op1 with continuation that builds Op2 -> Op3 -> Pure
      assert %Impure{sig: :Op1, k: k1} = result
      assert %Impure{sig: :Op2, k: k2} = k1.(:dummy)
      assert %Impure{sig: :Op3, k: k3} = k2.(:dummy)
      assert %Pure{val: :result} = k3.(:result)
    end
  end

  describe "~>> operator" do
    test "infix bind works like bind/2" do
      import Hefty, only: [~>>: 2]

      result =
        Hefty.pure(5)
        ~>> fn x -> Hefty.pure(x + 1) end
        ~>> fn x -> Hefty.pure(x * 2) end

      assert %Pure{val: 12} = result
    end

    test "operator has correct precedence" do
      import Hefty, only: [~>>: 2]

      result =
        Hefty.send_hefty(:Test, %{}, %{})
        ~>> fn x ->
          Hefty.pure(x + 1)
          ~>> fn y -> Hefty.pure(y * 2) end
        end

      assert %Impure{k: k} = result
      # (5 + 1) * 2 = 12
      assert k.(5) == Hefty.pure(12)
    end
  end

  describe "pattern matching on Hefty trees" do
    # Helper that returns union type to avoid type system warnings
    defp make_hefty(type, value) do
      case type do
        :pure -> Hefty.pure(value)
        :impure -> Hefty.send_hefty(:Test, %{data: value}, %{})
      end
    end

    test "can pattern match on Pure" do
      result =
        case make_hefty(:pure, 42) do
          %Pure{val: v} -> {:pure, v}
          %Impure{} -> :impure
        end

      assert result == {:pure, 42}
    end

    test "can pattern match on Impure" do
      result =
        case make_hefty(:impure, :value) do
          %Pure{} -> :pure
          %Impure{sig: sig, data: data} -> {sig, data}
        end

      assert result == {:Test, %{data: :value}}
    end

    test "can directly pattern match Pure in function head" do
      assert %Pure{val: 42} = Hefty.pure(42)
    end

    test "can directly pattern match Impure in function head" do
      assert %Impure{sig: :Test} = Hefty.send_hefty(:Test, %{}, %{})
    end

    test "can extract computation parameters from psi" do
      comp1 = Hefty.pure(1)
      comp2 = Hefty.pure(2)

      hefty =
        Hefty.send_hefty(
          :Catch,
          %{},
          %{try: comp1, catch: comp2}
        )

      %Impure{psi: psi} = hefty

      assert Map.fetch!(psi, :try) == comp1
      assert Map.fetch!(psi, :catch) == comp2
    end
  end

  describe "type examples from documentation" do
    test "Catch operation structure" do
      try_comp = Hefty.pure(42)
      catch_comp = Hefty.pure(0)

      catch_hefty =
        Hefty.send_hefty(
          :Catch,
          %{type: :any},
          %{
            try: try_comp,
            catch: catch_comp
          }
        )

      assert %Impure{
               sig: :Catch,
               data: %{type: :any},
               psi: %{try: ^try_comp, catch: ^catch_comp}
             } = catch_hefty
    end

    test "FxMap operation with indexed forks" do
      items = [1, 2, 3]
      comps = Enum.map(items, &Hefty.pure/1)
      forks = Enum.with_index(comps) |> Map.new(fn {c, i} -> {i, c} end)

      fx_map = Hefty.send_hefty(:FxMap, %{list: items}, forks)

      assert %Impure{
               sig: :FxMap,
               data: %{list: [1, 2, 3]},
               psi: psi
             } = fx_map

      assert %Pure{val: 1} = psi[0]
      assert %Pure{val: 2} = psi[1]
      assert %Pure{val: 3} = psi[2]
    end
  end

  describe "hefty macro with single expression" do
    # These tests verify that the hefty macro works correctly with single expressions
    # (no bindings), which is a valid but edge-case usage pattern.

    test "hefty with single return" do
      use Freyja.Syntax

      computation =
        hefty do
          return(:foo)
        end

      assert %Pure{val: :foo} = computation

      outcome = computation |> Run.run()
      assert outcome.result == :foo
    end

    test "hefty with single effect" do
      use Freyja.Syntax

      computation =
        hefty do
          State.get()
        end

      # hefty elaborates to Freer, so result is Freer.Impure
      assert %Freyja.Freer.Impure{sig: State, data: %State.Get{}} = computation

      outcome = computation |> State.Handler.run(42) |> Run.run()
      assert outcome.result == 42
    end

    test "hefty with single pure expression (not return)" do
      use Freyja.Syntax

      computation =
        hefty do
          Hefty.pure(:bar)
        end

      assert %Pure{val: :bar} = computation

      outcome = computation |> Run.run()
      assert outcome.result == :bar
    end

    test "hefty with single assignment and return" do
      use Freyja.Syntax

      computation =
        hefty do
          x = 42
          return(x)
        end

      outcome = computation |> Run.run()
      assert outcome.result == 42
    end
  end
end
