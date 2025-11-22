defmodule Freyja.Hefty.PrototypeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Integration tests for the Hefty algebras prototype.

  Tests the complete pipeline: Hefty → Elaborate → Freer → Interpret → Result

  Validates:
  - Catch higher-order effect elaboration
  - Lift effect for first-order effects
  - Two-phase execution (elaborate then interpret)
  - Integration with existing State and Error handlers
  - Control flow encoding in elaborated Freer
  """

  import Freyja.Freer.FreerBlock

  alias Freyja.Hefty
  alias Freyja.Run
  alias Freyja.Effects.Catch
  alias Freyja.Effects.Lift
  alias Freyja.Effects.Throw
  alias Freyja.Effects.Throw.Handler, as: ThrowHandler
  alias Freyja.Effects.State

  describe "Lift effect" do
    test "lifts simple Freer computation" do
      # Lift a pure Freer value
      computation = Lift.lift(Freyja.Freer.pure(42))

      outcome =
        computation
        |> Lift.Algebra.run()
        |> Run.run()

      assert 42 = outcome.result
    end

    test "lifts State.get" do
      computation = Lift.lift(State.get())

      outcome =
        computation
        |> Lift.Algebra.run()
        |> State.Handler.run(100)
        |> Run.run()

      assert 100 = outcome.result
    end

    test "lifts State operations and chains them" do
      freer_comp =
        con do
          x <- State.get()
          _ <- State.put(x + 10)
          y <- State.get()
          return(y)
        end

      computation = Lift.lift(freer_comp)

      outcome =
        computation
        |> Lift.Algebra.run()
        |> State.Handler.run(5)
        |> Run.run()

      assert 15 = outcome.result
      assert outcome.outputs[State.Handler] == 15
    end
  end

  describe "Catch effect - success path" do
    test "returns try block result when no error" do
      computation =
        Catch.catch_hefty(
          Hefty.pure(42),
          fn _err -> Hefty.pure(0) end
        )

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, 42} = outcome.result
    end

    test "executes try block with State effect" do
      try_block = Lift.lift(State.get())
      catch_block = Hefty.pure(999)

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(42)
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, 42} = outcome.result
    end

    test "chains multiple operations in try block" do
      try_block =
        Lift.lift(
          con do
            x <- State.get()
            _ <- State.put(x * 2)
            y <- State.get()
            return(y)
          end
        )

      catch_block = Hefty.pure(0)

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(5)
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, 10} = outcome.result
      # Note: State changes within RunCatching scope don't propagate out (yet)
      # This is a scoping question for full implementation
    end
  end

  describe "Catch effect - error path" do
    test "returns catch block result when error occurs" do
      try_block = Lift.lift(Throw.throw_error("boom"))
      catch_block = Hefty.pure(:recovered)

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, :recovered} = outcome.result
    end

    test "executes catch block with State effect" do
      try_block = Lift.lift(Throw.throw_error("error"))

      catch_block = Lift.lift(State.get())

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(99)
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, 99} = outcome.result
    end

    test "catch block can modify state" do
      try_block = Lift.lift(Throw.throw_error("error"))

      catch_block =
        Lift.lift(
          con do
            _ <- State.put(999)
            State.get()
          end
        )

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(0)
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, 999} = outcome.result
      assert outcome.outputs[State.Handler] == 999
    end
  end

  describe "Catch effect - complex scenarios" do
    test "conditional error based on State" do
      try_block =
        Lift.lift(
          con do
            x <- State.get()

            if x < 0 do
              Throw.throw_error("negative value")
            else
              return(x * 2)
            end
          end
        )

      catch_block = Hefty.pure(0)

      # With positive state - success
      outcome1 =
        Catch.catch_hefty(try_block, fn _err -> catch_block end)
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(5)
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, 10} = outcome1.result

      # With negative state - caught error
      outcome2 =
        Catch.catch_hefty(try_block, fn _err -> catch_block end)
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(-3)
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, 0} = outcome2.result
    end

    test "nested Catch operations" do
      inner_try = Lift.lift(Throw.throw_error("inner error"))
      inner_catch = Hefty.pure(:inner_recovered)
      inner = Catch.catch_hefty(inner_try, fn _err -> inner_catch end)

      outer_try = inner
      outer_catch = Hefty.pure(:outer_recovered)
      outer = Catch.catch_hefty(outer_try, fn _err -> outer_catch end)

      outcome =
        outer
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> ThrowHandler.run()
        |> Run.run()

      # Inner catch should handle the error
      assert {:ok, :inner_recovered} = outcome.result
    end

    test "catch with continuation after" do
      computation =
        Catch.catch_hefty(
          Lift.lift(Throw.throw_error("error")),
          fn _err -> Hefty.pure(10) end
        )
        |> Hefty.bind(fn x ->
          # Continuation doubles the result
          Hefty.pure(x * 2)
        end)

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> ThrowHandler.run()
        |> Run.run()

      # Catch returns 10, continuation doubles it
      assert {:ok, 20} = outcome.result
    end

    test "State modifications visible across catch boundary" do
      try_block =
        Lift.lift(
          con do
            _ <- State.put(100)
            Throw.throw_error("after setting state")
          end
        )

      catch_block = Lift.lift(State.get())

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(0)
        |> ThrowHandler.run()
        |> Run.run()

      # Non-transactional semantics: State changes persist through errors
      # The try block sets State=100, then throws
      # The catch block sees State=100 (not the initial state of 0)
      # This matches Heftia's default behavior
      assert {:ok, 100} = outcome.result
      assert outcome.outputs[State.Handler] == 100
    end
  end

  describe "Integration with bind" do
    test "bind after Catch" do
      computation =
        Catch.catch_hefty(
          Hefty.pure(5),
          fn _err -> Hefty.pure(0) end
        )
        |> Hefty.bind(fn x -> Hefty.pure(x + 1) end)
        |> Hefty.bind(fn x -> Hefty.pure(x * 2) end)

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> ThrowHandler.run()
        |> Run.run()

      # (5 + 1) * 2 = 12
      assert {:ok, 12} = outcome.result
    end

    test "bind with Lift in continuation" do
      computation =
        Catch.catch_hefty(
          Hefty.pure(5),
          fn _err -> Hefty.pure(0) end
        )
        |> Hefty.bind(fn x ->
          Lift.lift(State.put(x))
        end)
        |> Hefty.bind(fn _ ->
          Lift.lift(State.get())
        end)

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(999)
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, 5} = outcome.result
      assert outcome.outputs[State.Handler] == 5
    end
  end

  describe "Two-phase execution validation" do
    test "elaboration with interposition transforms computation structurally" do
      # This test validates that elaboration with interposition transforms the computation
      # The new approach uses interpose_with to structurally transform the tree,
      # replacing Throw operations with catch handler calls
      try_block = Lift.lift(Throw.throw_error("error"))
      catch_block = Hefty.pure(:fallback)

      hefty_tree = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      # Elaborate (phase 1)
      freer_tree =
        Freyja.Hefty.Elaborate.elaborate(
          hefty_tree,
          [Catch.Algebra, Lift.Algebra]
        )

      # With interposition, the Throw is caught during elaboration and replaced
      # with the catch handler result. Since catch returns Pure(:fallback),
      # the elaborated tree is Pure(:fallback)
      assert %Freyja.Freer.Pure{val: :fallback} = freer_tree

      # Now interpret (phase 2)
      outcome =
        freer_tree
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, :fallback} = outcome.result
    end

    test "algebras are applied before interpretation" do
      # Verify that Catch is elaborated away before State handler sees it
      computation =
        Catch.catch_hefty(
          Lift.lift(State.get()),
          fn _err -> Hefty.pure(0) end
        )

      outcome =
        computation
        |> Catch.Algebra.run()
        |> Lift.Algebra.run()
        |> State.Handler.run(42)
        |> ThrowHandler.run()
        |> Run.run()

      assert {:ok, 42} = outcome.result
    end

    test "pure computation with no algebras or handlers" do
      # Pure computations can be run directly
      computation = Hefty.pure(100)

      outcome = computation |> Run.run()

      assert 100 = outcome.result
    end
  end

  describe "Error handling" do
    test "missing algebra raises helpful error" do
      # Try to run Catch without providing its algebra
      computation =
        Catch.catch_hefty(
          Hefty.pure(42),
          fn _err -> Hefty.pure(0) end
        )

      assert_raise ArgumentError, ~r/No algebra found for signature/, fn ->
        computation
        |> ThrowHandler.run()
        |> Run.run()
      end
    end

    test "missing Lift algebra when using Lift" do
      computation = Lift.lift(State.get())

      assert_raise ArgumentError, ~r/No algebra found.*Lift/, fn ->
        computation
        |> Catch.Algebra.run()
        |> State.Handler.run(42)
        |> Run.run()
      end
    end
  end
end
