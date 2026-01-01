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

  describe "call/3 validation" do
    test "raises helpful error when given a plain value instead of computation" do
      error =
        assert_raise ArgumentError, fn ->
          Comp.call(42, Env.new(), fn v, e -> {v, e} end)
        end

      assert error.message =~ "Expected a computation, got: 42"
      assert error.message =~ "Forgot `return(value)` at the end of a comp block"
    end

    test "raises helpful error when given nil" do
      error =
        assert_raise ArgumentError, fn ->
          Comp.call(nil, Env.new(), fn v, e -> {v, e} end)
        end

      assert error.message =~ "Expected a computation, got: nil"
    end

    test "raises helpful error when given a 1-arity function" do
      error =
        assert_raise ArgumentError, fn ->
          Comp.call(fn _x -> :oops end, Env.new(), fn v, e -> {v, e} end)
        end

      assert error.message =~ "Expected a computation"
      assert error.message =~ "must be a 2-arity function"
    end

    test "bind raises when inner computation returns non-computation" do
      # Simulates forgetting return() - the function passed to bind returns a plain value
      comp = Comp.bind(Comp.pure(1), fn _a -> :not_a_computation end)

      error =
        assert_raise ArgumentError, fn ->
          Comp.run(comp, Env.new())
        end

      assert error.message =~ "Expected a computation, got: :not_a_computation"
      assert error.message =~ "Forgot `return(value)`"
    end

    test "run raises when given non-computation" do
      error =
        assert_raise ArgumentError, fn ->
          Comp.run(:not_a_computation, Env.new())
        end

      assert error.message =~ "Expected a computation, got: :not_a_computation"
    end

    test "flatten raises when inner value is not a computation" do
      # Comp.pure(:not_a_computation) returns a valid computation that yields :not_a_computation
      # flatten then tries to call :not_a_computation as a computation
      nested = Comp.pure(:not_a_computation)
      comp = Comp.flatten(nested)

      error =
        assert_raise ArgumentError, fn ->
          Comp.run(comp, Env.new())
        end

      assert error.message =~ "Expected a computation, got: :not_a_computation"
    end
  end
end
