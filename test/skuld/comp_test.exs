defmodule Skuld.CompTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Env

  describe "pure" do
    test "returns value" do
      comp = Comp.pure(42)
      assert {42, _env} = Comp.run(comp, Env.new())
    end
  end

  describe "bind" do
    test "sequences computations" do
      comp =
        Comp.bind(Comp.pure(1), fn a ->
          Comp.bind(Comp.pure(2), fn b ->
            Comp.pure(a + b)
          end)
        end)

      assert {3, _env} = Comp.run(comp, Env.new())
    end
  end

  describe "map" do
    test "transforms result" do
      comp = Comp.map(Comp.pure(5), &(&1 * 2))
      assert {10, _env} = Comp.run(comp, Env.new())
    end
  end

  describe "sequence" do
    test "collects results" do
      comps = [Comp.pure(1), Comp.pure(2), Comp.pure(3)]
      comp = Comp.sequence(comps)
      assert {[1, 2, 3], _env} = Comp.run(comp, Env.new())
    end

    test "empty list returns empty list" do
      comp = Comp.sequence([])
      assert {[], _env} = Comp.run(comp, Env.new())
    end
  end

  describe "traverse" do
    test "maps and sequences" do
      comp = Comp.traverse([1, 2, 3], fn x -> Comp.pure(x * 2) end)
      assert {[2, 4, 6], _env} = Comp.run(comp, Env.new())
    end
  end

  describe "then_do" do
    test "ignores first result" do
      comp = Comp.then_do(Comp.pure(:ignored), Comp.pure(:kept))
      assert {:kept, _env} = Comp.run(comp, Env.new())
    end
  end

  describe "flatten" do
    test "flattens nested computation" do
      nested = Comp.pure(Comp.pure(42))
      comp = Comp.flatten(nested)
      assert {42, _env} = Comp.run(comp, Env.new())
    end
  end
end
