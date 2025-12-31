defmodule Freyja.FreerTest do
  use ExUnit.Case

  require Logger
  import Freyja.Freer, only: [~>>: 2]
  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.State
  alias Freyja.Freer
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Pure
  alias Freyja.Run

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

  describe "bind/2 - monad laws" do
    test "left identity: pure(x) >>= f ≡ f(x)" do
      x = 42
      f = fn n -> Freer.pure(n + 1) end

      lhs = Freer.bind(Freer.pure(x), f)
      rhs = f.(x)

      assert lhs == rhs
    end

    test "right identity: m >>= pure ≡ m" do
      m = Freer.pure(42)

      lhs = Freer.bind(m, &Freer.pure/1)
      rhs = m

      assert lhs == rhs
    end

    test "associativity: (m >>= f) >>= g ≡ m >>= (λx -> f(x) >>= g)" do
      m = Freer.pure(42)
      f = fn n -> Freer.pure(n + 1) end
      g = fn n -> Freer.pure(n * 2) end

      lhs = Freer.bind(Freer.bind(m, f), g)
      rhs = Freer.bind(m, fn x -> Freer.bind(f.(x), g) end)

      # Both should produce Pure{val: 86}
      assert lhs == rhs
      assert %Pure{val: 86} = lhs
    end

    test "left identity with Impure f result: pure(x) >>= f ≡ f(x)" do
      # Test with a function that returns an Impure computation
      x = 10
      f = fn n -> State.put(n) end

      lhs = Freer.bind(Freer.pure(x), f)
      rhs = f.(x)

      # Structural equality holds for left identity even with Impure
      assert lhs == rhs
    end

    test "right identity with Impure m: m >>= pure ≡ m (verified by execution)" do
      # For Impure m, we verify by running since structural equality
      # won't hold (bind appends to the queue)
      m = State.get()

      lhs = Freer.bind(m, &Freer.pure/1)
      rhs = m

      # Verify structurally that bind appended pure to the queue
      assert %Impure{sig: State, data: %State.Get{}, q: q_lhs} = lhs
      assert %Impure{sig: State, data: %State.Get{}, q: q_rhs} = rhs
      assert length(q_lhs) == length(q_rhs) + 1

      # Verify by execution - both should produce the same result
      outcome_lhs = lhs |> State.Handler.run(42) |> Run.run()
      outcome_rhs = rhs |> State.Handler.run(42) |> Run.run()

      assert outcome_lhs.result == outcome_rhs.result
      assert outcome_lhs.result == 42
    end

    test "associativity with Impure m: (m >>= f) >>= g ≡ m >>= (λx -> f(x) >>= g)" do
      # Test associativity with Impure m, verified by execution
      m = State.get()
      f = fn n -> State.put(n * 2) end
      g = fn _ -> State.get() end

      lhs = Freer.bind(Freer.bind(m, f), g)
      rhs = Freer.bind(m, fn x -> Freer.bind(f.(x), g) end)

      # Both should produce the same result when run
      outcome_lhs = lhs |> State.Handler.run(5) |> Run.run()
      outcome_rhs = rhs |> State.Handler.run(5) |> Run.run()

      assert outcome_lhs.result == outcome_rhs.result
      assert outcome_lhs.result == 10
      assert outcome_lhs.outputs[State.Handler] == outcome_rhs.outputs[State.Handler]
    end

    test "associativity with chained Impure: multiple effects" do
      # More complex test with multiple effects chained
      m = State.get()

      f = fn n ->
        con do
          _ <- State.put(n + 10)
          State.get()
        end
      end

      g = fn n ->
        con do
          _ <- State.put(n * 2)
          State.get()
        end
      end

      lhs = Freer.bind(Freer.bind(m, f), g)
      rhs = Freer.bind(m, fn x -> Freer.bind(f.(x), g) end)

      # Both should produce the same result: start 5, +10 = 15, *2 = 30
      outcome_lhs = lhs |> State.Handler.run(5) |> Run.run()
      outcome_rhs = rhs |> State.Handler.run(5) |> Run.run()

      assert outcome_lhs.result == outcome_rhs.result
      assert outcome_lhs.result == 30
      assert outcome_lhs.outputs[State.Handler] == 30
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

  describe "~>> operator" do
    test "chains pure computations" do
      computation =
        Freer.pure(5)
        ~>> fn x ->
          Freer.pure(x * 2)
        end
        ~>> fn y ->
          Freer.pure(y + 3)
        end

      # (5 * 2) + 3 = 13
      assert %Freer.Pure{val: 13} = computation
    end

    test "chains effect operations" do
      computation =
        State.get()
        ~>> fn count ->
          State.put(count + 10)
          ~>> fn _unit ->
            State.get()
            ~>> fn new_count ->
              Freer.pure(new_count)
            end
          end
        end

      outcome =
        computation
        |> State.Handler.run(5)
        |> Run.run()

      # Initial: 5, after put: 15
      assert outcome.result == 15
      assert outcome.outputs[State.Handler] == 15
    end

    test "equivalent to bind" do
      # Using ~>>
      comp1 =
        Freer.pure(10)
        ~>> fn x ->
          Freer.pure(x + 5)
        end

      # Using bind
      comp2 = Freer.bind(Freer.pure(10), fn x -> Freer.pure(x + 5) end)

      assert comp1 == comp2
    end

    test "mixed with con do notation" do
      computation =
        con do
          x <- State.get()
          y <- State.put(x * 2) ~>> fn _unit -> State.get() end
          return({x, y})
        end

      outcome =
        computation
        |> State.Handler.run(7)
        |> Run.run()

      # x = 7, y = 14
      assert outcome.result == {7, 14}
    end

    test "operator precedence and associativity" do
      # Test that ~>> is left-associative
      computation =
        Freer.pure(1)
        ~>> fn x -> Freer.pure(x + 1) end
        ~>> fn x -> Freer.pure(x * 2) end
        ~>> fn x -> Freer.pure(x + 10) end

      # ((1 + 1) * 2) + 10 = 14
      assert %Freer.Pure{val: 14} = computation
    end
  end

  describe "con macro with single expression" do
    # These tests verify that the con macro works correctly with single expressions
    # (no bindings), which is a valid but edge-case usage pattern.

    test "con with single return" do
      computation =
        con do
          return(:foo)
        end

      assert %Pure{val: :foo} = computation

      outcome = computation |> Run.run()
      assert outcome.result == :foo
    end

    test "con with single effect" do
      computation =
        con do
          State.get()
        end

      assert %Impure{sig: State, data: %State.Get{}} = computation

      outcome = computation |> State.Handler.run(42) |> Run.run()
      assert outcome.result == 42
    end

    test "con with single pure expression (not return)" do
      computation =
        con do
          Freer.pure(:bar)
        end

      assert %Pure{val: :bar} = computation

      outcome = computation |> Run.run()
      assert outcome.result == :bar
    end

    test "con with single assignment and return" do
      computation =
        con do
          x = 42
          return(x)
        end

      outcome = computation |> Run.run()
      assert outcome.result == 42
    end
  end
end
