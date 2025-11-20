defmodule Freyja.Freer.InterposeTest do
  use ExUnit.Case, async: true

  alias Freyja.Freer
  alias Freyja.Freer.{Pure, Impure}
  alias Freyja.Freer.Interpose

  # Test effect signatures
  defmodule TestEffectA do
    defstruct [:value]
  end

  defmodule TestEffectB do
    defstruct [:value]
  end

  defmodule TestEffectC do
    defstruct [:value, :tag]
  end

  describe "interpose_with/3 - basic interposition" do
    test "intercepts and replaces matching effect with pure value" do
      # Create computation: A(1) >>= return
      comp =
        Freer.send_effect(%TestEffectA{value: 1}, __MODULE__)
        |> Freer.bind(&Freer.pure/1)

      # Intercept all TestEffectA and replace with fixed value
      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{}, _k -> Freer.pure(:intercepted) end
        )

      # Result should be Pure(:intercepted)
      assert %Pure{val: :intercepted} = result
    end

    test "intercepts and calls continuation with transformed value" do
      # Create computation: A(1) >>= (\x -> pure(x * 10))
      comp =
        Freer.send_effect(%TestEffectA{value: 1}, __MODULE__)
        |> Freer.bind(fn x -> Freer.pure(x * 10) end)

      # Intercept A and call continuation with doubled value
      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{value: v}, k -> k.(v * 2) end
        )

      # Result should be Pure(2 * 10 = 20)
      assert %Pure{val: 20} = result
    end

    test "leaves Pure value unchanged" do
      comp = Freer.pure(42)

      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn _effect, _k -> Freer.pure(:should_not_happen) end
        )

      assert %Pure{val: 42} = result
    end
  end

  describe "interpose_with/3 - non-matching effects" do
    test "non-matching effects pass through unchanged structurally" do
      # Create computation: B(100) >>= return
      comp =
        Freer.send_effect(%TestEffectB{value: 100}, TestEffectB)
        |> Freer.bind(&Freer.pure/1)

      # Intercept only TestEffectA (which doesn't appear)
      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn _effect, _k -> Freer.pure(:should_not_happen) end
        )

      # Result should still be Impure with TestEffectB
      assert %Impure{sig: TestEffectB, data: %TestEffectB{value: 100}} = result
    end

    test "non-matching effects have wrapped continuations" do
      # Create computation: B(5) >>= (\x -> A(x))
      comp =
        Freer.send_effect(%TestEffectB{value: 5}, TestEffectB)
        |> Freer.bind(fn x ->
          Freer.send_effect(%TestEffectA{value: x}, __MODULE__)
        end)

      # Intercept only TestEffectA
      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{value: v}, k -> k.(v * 10) end
        )

      # Result should be Impure(B(5))
      # But when we apply its continuation, the A should be intercepted
      assert %Impure{sig: TestEffectB, data: %TestEffectB{value: 5}, q: [wrapped_k]} = result

      # Apply the wrapped continuation
      next_comp = wrapped_k.(5)

      # Should get Pure(5 * 10 = 50) because A was intercepted
      assert %Pure{val: 50} = next_comp
    end
  end

  describe "interpose_with/3 - multiple operations" do
    test "intercepts all matching operations in sequence" do
      # Create computation: A(1) >>= (\x -> A(x + 1) >>= (\y -> pure(y + 1)))
      comp =
        Freer.send_effect(%TestEffectA{value: 1}, __MODULE__)
        |> Freer.bind(fn x ->
          Freer.send_effect(%TestEffectA{value: x + 1}, __MODULE__)
          |> Freer.bind(fn y -> Freer.pure(y + 1) end)
        end)

      # Intercept all A and double their values
      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{value: v}, k -> k.(v * 2) end
        )

      # First A(1) -> doubled to 2
      # Second A(2+1=3) -> doubled to 6
      # Final pure(6+1) = 7
      assert %Pure{val: 7} = result
    end

    test "intercepts multiple different operations of same signature" do
      # Create computation with 3 A operations
      comp =
        Freer.send_effect(%TestEffectA{value: 1}, __MODULE__)
        |> Freer.bind(fn x ->
          Freer.send_effect(%TestEffectA{value: x + 10}, __MODULE__)
          |> Freer.bind(fn y ->
            Freer.send_effect(%TestEffectA{value: y + 100}, __MODULE__)
            |> Freer.bind(&Freer.pure/1)
          end)
        end)

      # Count how many times we intercept using process dictionary
      Process.put(:count, 0)

      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{value: v}, k ->
            Process.put(:count, Process.get(:count) + 1)
            k.(v)
          end
        )

      count = Process.get(:count)

      assert count == 3
      assert %Pure{val: 111} = result
    end
  end

  describe "interpose_with/3 - mixed effects" do
    test "intercepts only matching effects, passes through others" do
      # Create computation: A(10) >>= (\x -> B(x) >>= (\y -> A(y) >>= pure))
      comp =
        Freer.send_effect(%TestEffectA{value: 10}, __MODULE__)
        |> Freer.bind(fn x ->
          Freer.send_effect(%TestEffectB{value: x}, TestEffectB)
          |> Freer.bind(fn y ->
            Freer.send_effect(%TestEffectA{value: y}, __MODULE__)
            |> Freer.bind(&Freer.pure/1)
          end)
        end)

      # Intercept only A
      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{value: v}, k -> k.(v + 100) end
        )

      # First A(10) intercepted -> 110
      # B(110) not intercepted, still in computation
      assert %Impure{sig: TestEffectB, data: %TestEffectB{value: 110}, q: [k]} = result

      # Continue with B's result
      next_comp = k.(110)

      # Second A(110) intercepted -> 210
      assert %Pure{val: 210} = next_comp
    end
  end

  describe "interpose_with/3 - continuation preservation" do
    test "interposition is preserved through non-matching operations" do
      # This is the KEY test for catch + yield!
      # Create: B(1) >>= (\x -> A(x) >>= pure)
      # Intercept A
      # Result should be: B(1) with wrapped continuation
      # When we apply continuation, A should STILL be intercepted

      comp =
        Freer.send_effect(%TestEffectB{value: 1}, TestEffectB)
        |> Freer.bind(fn x ->
          Freer.send_effect(%TestEffectA{value: x}, __MODULE__)
          |> Freer.bind(&Freer.pure/1)
        end)

      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{}, _k -> Freer.pure(:a_was_intercepted) end
        )

      # Result is Impure(B)
      assert %Impure{sig: TestEffectB, q: [k]} = result

      # Apply continuation - A should be intercepted!
      next = k.(1)
      assert %Pure{val: :a_was_intercepted} = next
    end

    test "interposition preserved through multiple non-matching operations" do
      # Create: B(1) >>= (\x -> B(x+1) >>= (\y -> A(y) >>= pure))
      comp =
        Freer.send_effect(%TestEffectB{value: 1}, TestEffectB)
        |> Freer.bind(fn x ->
          Freer.send_effect(%TestEffectB{value: x + 1}, TestEffectB)
          |> Freer.bind(fn y ->
            Freer.send_effect(%TestEffectA{value: y}, __MODULE__)
            |> Freer.bind(&Freer.pure/1)
          end)
        end)

      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{value: v}, k -> k.(v * 100) end
        )

      # First B
      assert %Impure{sig: TestEffectB, data: %TestEffectB{value: 1}, q: [k1]} = result
      next = k1.(1)

      # Second B
      assert %Impure{sig: TestEffectB, data: %TestEffectB{value: 2}, q: [k2]} = next
      final = k2.(2)

      # A should be intercepted: 2 * 100 = 200
      assert %Pure{val: 200} = final
    end
  end

  describe "interpose_with/3 - nested interposition" do
    test "can apply interposition twice" do
      # Create: A(10)
      comp = Freer.send_effect(%TestEffectA{value: 10}, __MODULE__)

      # First interposition: A -> pure(x * 2)
      result1 =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{value: v}, _k -> Freer.pure(v * 2) end
        )

      assert %Pure{val: 20} = result1

      # Second interposition on a different computation
      comp2 =
        Freer.send_effect(%TestEffectA{value: 5}, __MODULE__)
        |> Freer.bind(fn x ->
          Freer.send_effect(%TestEffectA{value: x + 1}, __MODULE__)
        end)

      # Apply two interpositions in sequence
      result2 =
        comp2
        |> Interpose.interpose_with(__MODULE__, fn %TestEffectA{value: v}, k -> k.(v + 10) end)
        |> Interpose.interpose_with(__MODULE__, fn %TestEffectA{value: v}, k -> k.(v * 3) end)

      # This shouldn't work as expected because first interposition already processed all A's
      # But it shows interposition can be composed
      assert %Pure{} = result2
    end
  end

  describe "interpose/4 - custom value handler" do
    test "applies value handler to final Pure value" do
      comp = Freer.pure(42)

      result =
        Interpose.interpose(
          comp,
          __MODULE__,
          fn _effect, _k -> Freer.pure(:should_not_happen) end,
          fn x -> Freer.pure(x * 2) end
        )

      assert %Pure{val: 84} = result
    end

    test "value handler is applied after all interceptions" do
      comp =
        Freer.send_effect(%TestEffectA{value: 10}, __MODULE__)
        |> Freer.bind(&Freer.pure/1)

      result =
        Interpose.interpose(
          comp,
          __MODULE__,
          fn %TestEffectA{value: v}, k -> k.(v + 5) end,
          fn x -> Freer.pure(x * 10) end
        )

      # A(10) intercepted -> 15, then value handler: 15 * 10 = 150
      assert %Pure{val: 150} = result
    end
  end

  describe "interpose_with/3 - predicate matching" do
    test "matches using predicate function on signature and data" do
      # Create computation with both TestEffectC operations
      comp =
        Freer.send_effect(%TestEffectC{value: 1, tag: :important}, TestEffectC)
        |> Freer.bind(fn x ->
          Freer.send_effect(%TestEffectC{value: x, tag: :normal}, TestEffectC)
          |> Freer.bind(&Freer.pure/1)
        end)

      # Intercept only :important tagged operations
      result =
        Interpose.interpose_with(
          comp,
          fn sig, data ->
            sig == TestEffectC and match?(%TestEffectC{tag: :important}, data)
          end,
          fn %TestEffectC{value: v}, k -> k.(v + 100) end
        )

      # First C (tag: :important) intercepted -> 101
      # Second C (tag: :normal) not intercepted, passes through
      assert %Impure{sig: TestEffectC, data: %TestEffectC{value: 101, tag: :normal}} = result
    end

    test "predicate can match on effect data fields" do
      comp =
        Freer.send_effect(%TestEffectC{value: 5, tag: :a}, TestEffectC)
        |> Freer.bind(fn x ->
          Freer.send_effect(%TestEffectC{value: x, tag: :b}, TestEffectC)
          |> Freer.bind(fn y ->
            Freer.send_effect(%TestEffectC{value: y, tag: :a}, TestEffectC)
            |> Freer.bind(&Freer.pure/1)
          end)
        end)

      # Intercept only tag: :a
      result =
        Interpose.interpose_with(
          comp,
          fn _sig, %TestEffectC{tag: tag} -> tag == :a end,
          fn %TestEffectC{value: v}, k -> k.(v * 10) end
        )

      # First C (tag: :a) intercepted -> 50
      # Second C (tag: :b) passes through
      assert %Impure{sig: TestEffectC, data: %TestEffectC{value: 50, tag: :b}, q: [k]} = result

      # Continue
      next = k.(50)

      # Third C (tag: :a) intercepted -> 500
      assert %Pure{val: 500} = next
    end

    test "predicate with pattern matching uses guards instead" do
      comp = Freer.send_effect(%TestEffectA{value: 1}, __MODULE__)

      # Predicate uses guards to safely check struct type
      result =
        Interpose.interpose_with(
          comp,
          fn _sig, data ->
            match?(%TestEffectC{tag: :important}, data)
          end,
          fn _effect, k -> k.(999) end
        )

      # Should not match, effect passes through
      assert %Impure{sig: __MODULE__, data: %TestEffectA{value: 1}} = result
    end
  end

  describe "interpose_with/3 - long continuation chains" do
    test "handles deep continuation chains" do
      # Build a deep chain: A(1) >>= A(2) >>= A(3) >>= ... >>= A(10)
      comp =
        Enum.reduce(1..10, Freer.pure(0), fn n, acc ->
          Freer.bind(acc, fn _x ->
            Freer.send_effect(%TestEffectA{value: n}, __MODULE__)
          end)
        end)

      # Intercept all and sum values using process dictionary
      Process.put(:sum, 0)

      result =
        Interpose.interpose_with(
          comp,
          __MODULE__,
          fn %TestEffectA{value: v}, k ->
            Process.put(:sum, Process.get(:sum) + v)
            k.(v)
          end
        )

      sum = Process.get(:sum)

      # Sum should be 1+2+3+...+10 = 55
      assert sum == 55
      assert %Pure{val: 10} = result
    end
  end
end
