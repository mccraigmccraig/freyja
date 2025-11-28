defmodule Freyja.Hefty.ElaborateTest do
  use ExUnit.Case, async: true

  alias Freyja.Hefty
  alias Freyja.Hefty.Elaborate
  alias Freyja.Hefty.Algebra
  alias Freyja.Freer

  # Simple test algebra that just returns the operation data as a value
  defmodule IdentityAlgebra do
    @behaviour Algebra

    @impl true
    def handles_hefty?(:Identity), do: true
    def handles_hefty?(_), do: false

    @impl true
    def elaborate(operation, _psi, k, _elaborator) do
      # Just continue with the operation data
      k.(operation)
    end
  end

  # Algebra that composes psi computations sequentially
  defmodule SequenceAlgebra do
    @behaviour Algebra

    @impl true
    def handles_hefty?(:Sequence), do: true
    def handles_hefty?(_), do: false

    @impl true
    def elaborate(%{comps: comp_keys}, psi, k, _elaborator) do
      # Sequence all computations in psi, collect results
      result_comp = sequence_comps(comp_keys, psi, [])
      Freer.bind(result_comp, k)
    end

    defp sequence_comps([], _psi, acc) do
      Freer.pure(Enum.reverse(acc))
    end

    defp sequence_comps([key | rest], psi, acc) do
      comp = Map.fetch!(psi, key)

      Freer.bind(comp, fn value ->
        sequence_comps(rest, psi, [value | acc])
      end)
    end
  end

  # Algebra that uses values from psi in computation
  defmodule CombineAlgebra do
    @behaviour Algebra

    @impl true
    def handles_hefty?(:Combine), do: true
    def handles_hefty?(_), do: false

    @impl true
    def elaborate(%{op: op}, psi, k, _elaborator) do
      left = Map.fetch!(psi, :left)
      right = Map.fetch!(psi, :right)

      combined =
        Freer.bind(left, fn l ->
          Freer.bind(right, fn r ->
            result =
              case op do
                :add -> l + r
                :mul -> l * r
                :concat -> "#{l}#{r}"
              end

            Freer.pure(result)
          end)
        end)

      Freer.bind(combined, k)
    end
  end

  describe "elaborate/2 with Pure" do
    test "pure values pass through to Freer.pure" do
      hefty = Hefty.pure(42)
      algebras = []

      result = Elaborate.elaborate(hefty, algebras)

      assert %Freer.Pure{val: 42} = result
    end

    test "pure values with any type" do
      assert %Freer.Pure{val: "hello"} =
               Elaborate.elaborate(Hefty.pure("hello"), [])

      assert %Freer.Pure{val: [1, 2, 3]} =
               Elaborate.elaborate(Hefty.pure([1, 2, 3]), [])

      assert %Freer.Pure{val: %{key: :value}} =
               Elaborate.elaborate(Hefty.pure(%{key: :value}), [])
    end
  end

  describe "elaborate/2 with Impure" do
    test "elaborates simple operation with no forks" do
      hefty = Hefty.send_hefty(:Identity, %{data: 42}, %{})
      algebras = [IdentityAlgebra]

      result = Elaborate.elaborate(hefty, algebras)

      # Identity algebra continues with the operation data
      assert %Freer.Pure{val: %{data: 42}} = result
    end

    test "elaborates operation with continuation" do
      hefty =
        Hefty.send_hefty(:Identity, %{data: 5}, %{})
        |> Hefty.bind(fn %{data: x} -> Hefty.pure(x * 2) end)

      algebras = [IdentityAlgebra]

      result = Elaborate.elaborate(hefty, algebras)

      # Should apply continuation: 5 * 2 = 10
      assert %Freer.Pure{val: 10} = result
    end

    test "raises when no algebra handles signature" do
      hefty = Hefty.send_hefty(:UnknownEffect, %{}, %{})
      algebras = [IdentityAlgebra]

      assert_raise ArgumentError, ~r/No algebra found for signature: :UnknownEffect/, fn ->
        Elaborate.elaborate(hefty, algebras)
      end
    end

    test "error message suggests how to fix missing algebra" do
      hefty = Hefty.send_hefty(:MyEffect, %{}, %{})

      assert_raise ArgumentError, fn ->
        Elaborate.elaborate(hefty, [])
      end
    end
  end

  describe "elaborate/2 with computation parameters (psi)" do
    test "elaborates forks bottom-up before calling algebra" do
      # Create operation with two pure forks
      left = Hefty.pure(10)
      right = Hefty.pure(5)

      hefty =
        Hefty.send_hefty(
          :Combine,
          %{op: :add},
          %{left: left, right: right}
        )

      algebras = [CombineAlgebra]

      result = Elaborate.elaborate(hefty, algebras)

      # Should compute 10 + 5 = 15
      assert %Freer.Pure{val: 15} = result
    end

    test "elaborates nested operations in forks" do
      # Nested structure: Combine(Combine(3, 2, :mul), 10, :add)
      #                   = Combine(6, 10, :add) = 16
      inner_left = Hefty.pure(3)
      inner_right = Hefty.pure(2)

      inner_combine =
        Hefty.send_hefty(
          :Combine,
          %{op: :mul},
          %{left: inner_left, right: inner_right}
        )

      outer_right = Hefty.pure(10)

      outer_combine =
        Hefty.send_hefty(
          :Combine,
          %{op: :add},
          %{left: inner_combine, right: outer_right}
        )

      algebras = [CombineAlgebra]

      result = Elaborate.elaborate(outer_combine, algebras)

      # (3 * 2) + 10 = 16
      assert %Freer.Pure{val: 16} = result
    end

    test "algebra receives already-elaborated Freer in psi" do
      # This test verifies the key property: algebras receive Freer, not Hefty
      left = Hefty.pure(100)
      right = Hefty.pure(50)

      hefty =
        Hefty.send_hefty(
          :Combine,
          %{op: :add},
          %{left: left, right: right}
        )

      algebras = [CombineAlgebra]

      result = Elaborate.elaborate(hefty, algebras)

      # The algebra works with Freer.bind, proving psi values are Freer
      assert %Freer.Pure{val: 150} = result
    end

    test "sequence multiple computations from psi" do
      comp1 = Hefty.pure(1)
      comp2 = Hefty.pure(2)
      comp3 = Hefty.pure(3)

      hefty =
        Hefty.send_hefty(
          :Sequence,
          %{comps: [:a, :b, :c]},
          %{a: comp1, b: comp2, c: comp3}
        )

      algebras = [SequenceAlgebra]

      result = Elaborate.elaborate(hefty, algebras)

      assert %Freer.Pure{val: [1, 2, 3]} = result
    end
  end

  describe "elaborate/2 with continuation" do
    test "continuation is elaborated and composed" do
      hefty =
        Hefty.send_hefty(:Identity, %{data: 5}, %{})
        |> Hefty.bind(fn %{data: x} -> Hefty.pure(x + 1) end)
        |> Hefty.bind(fn x -> Hefty.pure(x * 2) end)

      algebras = [IdentityAlgebra]

      result = Elaborate.elaborate(hefty, algebras)

      # (5 + 1) * 2 = 12
      assert %Freer.Pure{val: 12} = result
    end

    test "continuation can create new operations" do
      outer_hefty =
        Hefty.send_hefty(:Identity, %{data: 5}, %{})
        |> Hefty.bind(fn %{data: x} ->
          # Continuation creates another operation
          Hefty.send_hefty(:Identity, %{data: x * 2}, %{})
        end)

      algebras = [IdentityAlgebra]

      result = Elaborate.elaborate(outer_hefty, algebras)

      # The outer Identity returns %{data: 5}, continuation creates
      # another Identity with %{data: 10}, which returns %{data: 10}
      assert %Freer.Pure{val: %{data: 10}} = result
    end
  end

  describe "elaborate/2 - multiple algebras" do
    test "dispatches to correct algebra based on signature" do
      identity_op = Hefty.send_hefty(:Identity, %{data: 42}, %{})

      combine_op =
        Hefty.send_hefty(
          :Combine,
          %{op: :mul},
          %{left: Hefty.pure(6), right: Hefty.pure(7)}
        )

      algebras = [IdentityAlgebra, CombineAlgebra]

      result1 = Elaborate.elaborate(identity_op, algebras)
      assert %Freer.Pure{val: %{data: 42}} = result1

      result2 = Elaborate.elaborate(combine_op, algebras)
      assert %Freer.Pure{val: 42} = result2
    end

    test "order of algebras doesn't matter (dispatch by signature)" do
      combine_op =
        Hefty.send_hefty(
          :Combine,
          %{op: :add},
          %{left: Hefty.pure(10), right: Hefty.pure(20)}
        )

      # Try both orders
      algebras1 = [IdentityAlgebra, CombineAlgebra]
      algebras2 = [CombineAlgebra, IdentityAlgebra]

      result1 = Elaborate.elaborate(combine_op, algebras1)
      result2 = Elaborate.elaborate(combine_op, algebras2)

      assert result1 == result2
      assert %Freer.Pure{val: 30} = result1
    end
  end

  describe "elaborate/2 - error handling" do
    test "clear error when algebra missing" do
      hefty = Hefty.send_hefty(:MissingEffect, %{}, %{})

      error =
        assert_raise ArgumentError, fn ->
          Elaborate.elaborate(hefty, [])
        end

      assert error.message =~ "No algebra found for signature: :MissingEffect"
      assert error.message =~ "Available algebras"
      assert error.message =~ "@behaviour Freyja.Hefty.Algebra"
    end

    test "error when module is not an algebra" do
      defmodule NotAnAlgebra do
        # Missing @behaviour and callbacks
      end

      hefty = Hefty.send_hefty(:Test, %{}, %{})

      assert_raise ArgumentError, ~r/does not implement Freyja.Hefty.Algebra/, fn ->
        Elaborate.elaborate(hefty, [NotAnAlgebra])
      end
    end
  end

  describe "elaborate/2 - complex scenarios" do
    test "deeply nested operations with multiple effects" do
      # Build: Combine(Combine(10, 5, :add), Combine(3, 2, :mul), :mul)
      #      = Combine(15, 6, :mul) = 90

      left_inner =
        Hefty.send_hefty(
          :Combine,
          %{op: :add},
          %{left: Hefty.pure(10), right: Hefty.pure(5)}
        )

      right_inner =
        Hefty.send_hefty(
          :Combine,
          %{op: :mul},
          %{left: Hefty.pure(3), right: Hefty.pure(2)}
        )

      outer =
        Hefty.send_hefty(
          :Combine,
          %{op: :mul},
          %{left: left_inner, right: right_inner}
        )

      algebras = [CombineAlgebra]

      result = Elaborate.elaborate(outer, algebras)

      # (10 + 5) * (3 * 2) = 15 * 6 = 90
      assert %Freer.Pure{val: 90} = result
    end

    test "operation with many forks" do
      forks =
        0..9
        |> Enum.map(fn i -> {i, Hefty.pure(i)} end)
        |> Map.new()

      hefty =
        Hefty.send_hefty(
          :Sequence,
          %{comps: Enum.to_list(0..9)},
          forks
        )

      algebras = [SequenceAlgebra]

      result = Elaborate.elaborate(hefty, algebras)

      assert %Freer.Pure{val: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]} = result
    end

    test "bottom-up elaboration order" do
      # This test verifies that inner operations are elaborated
      # before outer ones (bottom-up fold)

      # Track elaboration order
      send(self(), {:elaborate_order, []})

      defmodule OrderTrackingAlgebra do
        @behaviour Algebra

        @impl true
        def handles_hefty?(:Track), do: true
        def handles_hefty?(_), do: false

        @impl true
        def elaborate(%{id: id}, _psi, k, _elaborator) do
          # Send message when this algebra runs
          test_pid = Process.whereis(:elaborate_test)
          send(test_pid, {:elaborated, id})
          k.(id)
        end
      end

      # Register test process
      Process.register(self(), :elaborate_test)

      # Create nested structure: outer(inner1, inner2)
      inner1 = Hefty.send_hefty(:Track, %{id: :inner1}, %{})
      inner2 = Hefty.send_hefty(:Track, %{id: :inner2}, %{})

      outer =
        Hefty.send_hefty(
          :Track,
          %{id: :outer},
          %{left: inner1, right: inner2}
        )

      algebras = [OrderTrackingAlgebra]

      _result = Elaborate.elaborate(outer, algebras)

      # Collect elaboration order
      order = receive_all_elaborated([])

      # Inner operations should be elaborated before outer
      assert order == [:inner1, :inner2, :outer] or order == [:inner2, :inner1, :outer]
      assert List.last(order) == :outer

      # Cleanup
      Process.unregister(:elaborate_test)
    end
  end

  # Helper to collect all :elaborated messages
  defp receive_all_elaborated(acc) do
    receive do
      {:elaborated, id} -> receive_all_elaborated([id | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
