defmodule Freyja.Hefty.Effects.HeftyFxListTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for HeftyFxList - the clean Hefty implementation of fx_map.

  This demonstrates the power of Hefty algebras:
  - ~20 line algebra vs ~150 line old handler
  - No manual continuation management
  - No ScopedOk/ScopedError
  - No suspension special cases
  - Self-explanatory code
  """

  import Freyja.HeftyMacro

  alias Freyja.Hefty
  alias Freyja.Hefty.Run, as: HeftyRun
  alias Freyja.Hefty.Effects.HeftyFxList
  alias Freyja.Hefty.Effects.HeftyFxList.FxMap
  alias Freyja.Hefty.Effects.Lift
  alias Freyja.Effects.State
  alias Freyja.OkResult

  # Helper for comparison test
  defmodule ComparisonHelper do
    import Freyja.HeftyMacro
    alias Freyja.Effects.State

    defhefty process_item(x) do
      count <- State.get()
      State.put(count + 1)
      return(x * 2)
    end
  end

  describe "fx_map/2 - basic functionality" do
    test "maps pure function over list" do
      computation =
        HeftyFxList.fx_map([1, 2, 3], fn x ->
          Hefty.pure(x * 2)
        end)

      outcome =
        HeftyRun.run(
          computation,
          [HeftyFxList.Algebra, Lift.Algebra],
          []
        )

      assert %OkResult{value: [2, 4, 6]} = outcome.result
    end

    test "maps over empty list" do
      computation =
        HeftyFxList.fx_map([], fn x ->
          Hefty.pure(x * 2)
        end)

      outcome =
        HeftyRun.run(
          computation,
          [HeftyFxList.Algebra, Lift.Algebra],
          []
        )

      assert %OkResult{value: []} = outcome.result
    end

    test "maps over single element" do
      computation =
        HeftyFxList.fx_map([42], fn x ->
          Hefty.pure(x + 1)
        end)

      outcome =
        HeftyRun.run(
          computation,
          [HeftyFxList.Algebra, Lift.Algebra],
          []
        )

      assert %OkResult{value: [43]} = outcome.result
    end

    test "function can use hefty blocks" do
      computation =
        HeftyFxList.fx_map([1, 2, 3], fn x ->
          hefty do
            y = x * 2
            z = y + 1
            return(z)
          end
        end)

      outcome =
        HeftyRun.run(
          computation,
          [HeftyFxList.Algebra, Lift.Algebra],
          []
        )

      assert %OkResult{value: [3, 5, 7]} = outcome.result
    end
  end

  describe "fx_map/2 - with first-order effects (auto-lifted)" do
    test "function uses State effect" do
      computation =
        HeftyFxList.fx_map([1, 2, 3], fn x ->
          hefty do
            # Auto-lifted
            count <- State.get()
            # Auto-lifted
            State.put(count + 1)
            return(x * 2)
          end
        end)

      outcome =
        HeftyRun.run(
          computation,
          [HeftyFxList.Algebra, Lift.Algebra],
          [State.Handler],
          %{State.Handler => 0}
        )

      assert %OkResult{value: [2, 4, 6]} = outcome.result
      # State should be incremented 3 times
      assert outcome.outputs[State.Handler] == 3
    end

    test "function modifies and reads state" do
      computation =
        HeftyFxList.fx_map([10, 20, 30], fn x ->
          hefty do
            current <- State.get()
            State.put(current + x)
            new_val <- State.get()
            return(new_val)
          end
        end)

      outcome =
        HeftyRun.run(
          computation,
          [HeftyFxList.Algebra, Lift.Algebra],
          [State.Handler],
          %{State.Handler => 0}
        )

      # 0 + 10 = 10, 10 + 20 = 30, 30 + 30 = 60
      assert %OkResult{value: [10, 30, 60]} = outcome.result
      assert outcome.outputs[State.Handler] == 60
    end
  end

  describe "fx_map/2 - composition with other effects" do
    test "fx_map can be bound" do
      computation =
        HeftyFxList.fx_map([1, 2, 3], fn x -> Hefty.pure(x * 2) end)
        |> Hefty.bind(fn results -> Hefty.pure(Enum.sum(results)) end)

      outcome =
        HeftyRun.run(
          computation,
          [HeftyFxList.Algebra, Lift.Algebra],
          []
        )

      # [2, 4, 6] → sum = 12
      assert %OkResult{value: 12} = outcome.result
    end

    test "fx_map in hefty block" do
      computation =
        hefty do
          State.put(0)

          results <-
            HeftyFxList.fx_map([1, 2, 3], fn x ->
              hefty do
                count <- State.get()
                State.put(count + 1)
                return(x * count)
              end
            end)

          final_count <- State.get()
          return({results, final_count})
        end

      outcome =
        HeftyRun.run(
          computation,
          [HeftyFxList.Algebra, Lift.Algebra],
          [State.Handler],
          %{State.Handler => 0}
        )

      # count: 0, 1, 2 → results: [0, 2, 6]
      assert %OkResult{value: {[0, 2, 6], 3}} = outcome.result
    end

    test "nested fx_map" do
      computation =
        HeftyFxList.fx_map([1, 2], fn x ->
          HeftyFxList.fx_map([10, 20], fn y ->
            Hefty.pure(x + y)
          end)
        end)

      outcome =
        HeftyRun.run(
          computation,
          [HeftyFxList.Algebra, Lift.Algebra],
          []
        )

      # [[11, 21], [12, 22]]
      assert %OkResult{value: [[11, 21], [12, 22]]} = outcome.result
    end
  end

  describe "fx_map/2 - demonstrates simplicity" do
    test "elaboration is simple - just sequences computations" do
      # This test documents the simplicity

      list = [1, 2, 3]
      f = fn x -> Hefty.pure(x * 2) end

      hefty_tree = HeftyFxList.fx_map(list, f)

      # Verify structure before elaboration
      assert %Hefty.Impure{
               sig: HeftyFxList,
               data: %FxMap{list: ^list, f: ^f},
               psi: psi
             } = hefty_tree

      # Should have one fork per element
      assert map_size(psi) == 3
      assert %Hefty.Pure{val: 2} = psi[0]
      assert %Hefty.Pure{val: 4} = psi[1]
      assert %Hefty.Pure{val: 6} = psi[2]

      # Elaborate
      freer_tree =
        Freyja.Hefty.Elaborate.elaborate(hefty_tree, [HeftyFxList.Algebra, Lift.Algebra])

      # For this simple case (pure values), elaboration produces Pure
      # In more complex cases with effects, would be Impure
      assert %Freyja.Freer.Pure{val: [2, 4, 6]} = freer_tree

      # Run it
      outcome = Freyja.Run.run(freer_tree, Freyja.Run.with_handlers([]))

      assert %OkResult{value: [2, 4, 6]} = outcome.result
    end
  end

end
