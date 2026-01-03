defmodule Skuld.Effects.FxListTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Effects.FxList
  alias Skuld.Effects.State

  describe "fx_map" do
    test "maps effectful function over empty list" do
      comp =
        FxList.fx_map([], fn x -> Comp.pure(x * 2) end)

      assert Comp.run!(comp) == []
    end

    test "maps effectful function over list" do
      comp =
        FxList.fx_map([1, 2, 3], fn x -> Comp.pure(x * 2) end)

      assert Comp.run!(comp) == [2, 4, 6]
    end

    test "maps with stateful effects" do
      comp =
        FxList.fx_map([1, 2, 3], fn x ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              Comp.pure({x, count})
            end)
          end)
        end)
        |> State.with_handler(0)

      assert Comp.run!(comp) == [{1, 0}, {2, 1}, {3, 2}]
    end
  end

  describe "fx_reduce" do
    test "reduces empty list to initial value" do
      comp =
        FxList.fx_reduce([], 0, fn x, acc -> Comp.pure(acc + x) end)

      assert Comp.run!(comp) == 0
    end

    test "reduces list with effectful function" do
      comp =
        FxList.fx_reduce([1, 2, 3, 4], 0, fn x, acc -> Comp.pure(acc + x) end)

      assert Comp.run!(comp) == 10
    end

    test "reduces with stateful effects" do
      comp =
        FxList.fx_reduce([1, 2, 3], [], fn x, acc ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              Comp.pure([{x, count} | acc])
            end)
          end)
        end)
        |> State.with_handler(0)

      assert Comp.run!(comp) == [{3, 2}, {2, 1}, {1, 0}]
    end
  end

  describe "fx_each" do
    test "executes effectful function for each element" do
      comp =
        Comp.bind(
          FxList.fx_each([1, 2, 3], fn x ->
            Comp.bind(State.get(), fn acc ->
              State.put([x | acc])
            end)
          end),
          fn :ok ->
            State.get()
          end
        )
        |> State.with_handler([])

      assert Comp.run!(comp) == [3, 2, 1]
    end

    test "returns :ok" do
      comp =
        FxList.fx_each([1, 2, 3], fn _ -> Comp.pure(:ignored) end)

      assert Comp.run!(comp) == :ok
    end

    test "works with range" do
      comp =
        Comp.bind(
          FxList.fx_each(1..5, fn _ ->
            Comp.bind(State.get(), fn n ->
              State.put(n + 1)
            end)
          end),
          fn :ok ->
            State.get()
          end
        )
        |> State.with_handler(0)

      assert Comp.run!(comp) == 5
    end
  end

  describe "fx_filter" do
    test "filters empty list" do
      comp =
        FxList.fx_filter([], fn x -> Comp.pure(x > 0) end)

      assert Comp.run!(comp) == []
    end

    test "filters list with pure predicate" do
      comp =
        FxList.fx_filter([1, 2, 3, 4, 5], fn x -> Comp.pure(rem(x, 2) == 0) end)

      assert Comp.run!(comp) == [2, 4]
    end

    test "filters with stateful predicate" do
      # Keep only elements where state counter is even
      comp =
        FxList.fx_filter([1, 2, 3, 4, 5], fn _x ->
          Comp.bind(State.get(), fn count ->
            Comp.bind(State.put(count + 1), fn _ ->
              Comp.pure(rem(count, 2) == 0)
            end)
          end)
        end)
        |> State.with_handler(0)

      # count=0 (even) -> keep 1
      # count=1 (odd) -> drop 2
      # count=2 (even) -> keep 3
      # count=3 (odd) -> drop 4
      # count=4 (even) -> keep 5
      assert Comp.run!(comp) == [1, 3, 5]
    end
  end
end
