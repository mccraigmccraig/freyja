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

  alias Freyja.Hefty
  alias Freyja.Hefty.Run, as: HeftyRun
  alias Freyja.Effects.Catch
  alias Freyja.Effects.Catch.RunCatchingHandler
  alias Freyja.Effects.Lift
  alias Freyja.Effects.Error
  alias Freyja.Effects.Error.Handler, as: ErrorHandler
  alias Freyja.Effects.State

  # Silence warning - RunCatchingHandler is passed as atom in handler lists
  _ = RunCatchingHandler

  describe "Lift effect" do
    test "lifts simple Freer computation" do
      # Lift a pure Freer value
      computation = Lift.lift(Freyja.Freer.pure(42))

      outcome = HeftyRun.run(
        computation,
        [Lift.Algebra],
        []
      )

      assert 42 = outcome.result
    end

    test "lifts State.get" do
      computation = Lift.lift(State.get())

      outcome = HeftyRun.run(
        computation,
        [Lift.Algebra],
        [State.Handler],
        %{State.Handler => 100}
      )

      assert 100 = outcome.result
    end

    test "lifts State operations and chains them" do
      import Freyja.Con

      freer_comp = con do
        x <- State.get()
        State.put(x + 10)
        y <- State.get()
        return(y)
      end

      computation = Lift.lift(freer_comp)

      outcome = HeftyRun.run(
        computation,
        [Lift.Algebra],
        [State.Handler],
        %{State.Handler => 5}
      )

      assert 15 = outcome.result
      assert outcome.outputs[State.Handler] == 15
    end
  end

  describe "Catch effect - success path" do
    test "returns try block result when no error" do
      computation = Catch.catch_hefty(
        Hefty.pure(42),
        fn _err -> Hefty.pure(0) end
      )

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [ErrorHandler, Catch.RunCatchingHandler]
      )

      assert 42 = outcome.result
    end

    test "executes try block with State effect" do
      try_block = Lift.lift(State.get())
      catch_block = Hefty.pure(999)

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, ErrorHandler, Catch.RunCatchingHandler],
        %{State.Handler => 42}
      )

      assert 42 = outcome.result
    end

    test "chains multiple operations in try block" do
      import Freyja.Con

      try_block = Lift.lift(con do
        x <- State.get()
        State.put(x * 2)
        y <- State.get()
        return(y)
      end)

      catch_block = Hefty.pure(0)

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, ErrorHandler, Catch.RunCatchingHandler],
        %{State.Handler => 5}
      )

      assert 10 = outcome.result
      # Note: State changes within RunCatching scope don't propagate out (yet)
      # This is a scoping question for full implementation
    end
  end

  describe "Catch effect - error path" do
    test "returns catch block result when error occurs" do
      try_block = Lift.lift(Error.throw_error("boom"))
      catch_block = Hefty.pure(:recovered)

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [ErrorHandler, Catch.RunCatchingHandler]
      )

      assert :recovered = outcome.result
    end

    test "executes catch block with State effect" do
      try_block = Lift.lift(Error.throw_error("error"))

      catch_block = Lift.lift(State.get())

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, ErrorHandler, Catch.RunCatchingHandler],
        %{State.Handler => 99}
      )

      assert 99 = outcome.result
    end

    test "catch block can modify state" do
      import Freyja.Con

      try_block = Lift.lift(Error.throw_error("error"))

      catch_block = Lift.lift(con do
        State.put(999)
        State.get()
      end)

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, ErrorHandler, Catch.RunCatchingHandler],
        %{State.Handler => 0}
      )

      assert 999 = outcome.result
      assert outcome.outputs[State.Handler] == 999
    end
  end

  describe "Catch effect - complex scenarios" do
    test "conditional error based on State" do
      import Freyja.Con

      try_block = Lift.lift(con do
        x <- State.get()
        if x < 0 do
          Error.throw_error("negative value")
        else
          return(x * 2)
        end
      end)

      catch_block = Hefty.pure(0)

      # With positive state - success
      outcome1 = HeftyRun.run(
        Catch.catch_hefty(try_block, fn _err -> catch_block end),
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, ErrorHandler, Catch.RunCatchingHandler],
        %{State.Handler => 5}
      )

      assert 10 = outcome1.result

      # With negative state - caught error
      outcome2 = HeftyRun.run(
        Catch.catch_hefty(try_block, fn _err -> catch_block end),
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, ErrorHandler, Catch.RunCatchingHandler],
        %{State.Handler => -3}
      )

      assert 0 = outcome2.result
    end

    test "nested Catch operations" do
      import Freyja.Con

      inner_try = Lift.lift(Error.throw_error("inner error"))
      inner_catch = Hefty.pure(:inner_recovered)
      inner = Catch.catch_hefty(inner_try, fn _err -> inner_catch end)

      outer_try = inner
      outer_catch = Hefty.pure(:outer_recovered)
      outer = Catch.catch_hefty(outer_try, fn _err -> outer_catch end)

      outcome = HeftyRun.run(
        outer,
        [Catch.Algebra, Lift.Algebra],
        [ErrorHandler, Catch.RunCatchingHandler]
      )

      # Inner catch should handle the error
      assert :inner_recovered = outcome.result
    end

    test "catch with continuation after" do
      import Freyja.Con

      computation =
        Catch.catch_hefty(
          Lift.lift(Error.throw_error("error")),
          fn _err -> Hefty.pure(10) end
        )
        |> Hefty.bind(fn x ->
          # Continuation doubles the result
          Hefty.pure(x * 2)
        end)

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [ErrorHandler, Catch.RunCatchingHandler]
      )

      # Catch returns 10, continuation doubles it
      assert 20 = outcome.result
    end

    test "State modifications visible across catch boundary" do
      import Freyja.Con

      try_block = Lift.lift(con do
        State.put(100)
        Error.throw_error("after setting state")
      end)

      catch_block = Lift.lift(State.get())

      computation = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, ErrorHandler, Catch.RunCatchingHandler],
        %{State.Handler => 0}
      )

      # Non-transactional semantics: State changes persist through errors
      # The try block sets State=100, then throws
      # The catch block sees State=100 (not the initial state of 0)
      # This matches Heftia's default behavior
      assert 100 = outcome.result
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

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [ErrorHandler, Catch.RunCatchingHandler]
      )

      # (5 + 1) * 2 = 12
      assert 12 = outcome.result
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

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, ErrorHandler, Catch.RunCatchingHandler],
        %{State.Handler => 999}
      )

      assert 5 = outcome.result
      assert outcome.outputs[State.Handler] == 5
    end
  end

  describe "Two-phase execution validation" do
    test "elaboration produces Freer with case statement for control flow" do
      # This test validates that elaboration encodes control flow as case statements
      try_block = Lift.lift(Error.throw_error("error"))
      catch_block = Hefty.pure(:fallback)

      hefty_tree = Catch.catch_hefty(try_block, fn _err -> catch_block end)

      # Elaborate (phase 1)
      freer_tree = Freyja.Hefty.Elaborate.elaborate(
        hefty_tree,
        [Catch.Algebra, Lift.Algebra]
      )

      # The freer_tree should be an Impure node (Catch.Algebra.run_catching)
      assert %Freyja.Freer.Impure{sig: Catch.Algebra} = freer_tree

      # Now interpret (phase 2)
      run_state = Freyja.Run.with_handlers([
        {ErrorHandler, ErrorHandler},
        {Catch.RunCatchingHandler, Catch.RunCatchingHandler}
      ])
      outcome = Freyja.Run.run(freer_tree, run_state)

      assert :fallback = outcome.result
    end

    test "algebras are applied before interpretation" do
      # Verify that Catch is elaborated away before State handler sees it
      computation = Catch.catch_hefty(
        Lift.lift(State.get()),
        fn _err -> Hefty.pure(0) end
      )

      outcome = HeftyRun.run(
        computation,
        [Catch.Algebra, Lift.Algebra],
        [State.Handler, ErrorHandler, Catch.RunCatchingHandler],  # Need ErrorHandler, Catch.RunCatchingHandler for catch_fx
        %{State.Handler => 42}
      )

      assert 42 = outcome.result
    end

    test "run_simple convenience function" do
      # run_simple doesn't provide handlers, so can't use Catch
      # Use pure computation instead
      computation = Hefty.pure(100)

      outcome = HeftyRun.run_simple(
        computation,
        []  # No algebras needed for pure
      )

      assert 100 = outcome.result
    end
  end

  describe "Error handling" do
    test "missing algebra raises helpful error" do
      # Try to run Catch without providing its algebra
      computation = Catch.catch_hefty(
        Hefty.pure(42),
        fn _err -> Hefty.pure(0) end
      )

      assert_raise ArgumentError, ~r/No algebra found for signature/, fn ->
        HeftyRun.run(computation, [], [])
      end
    end

    test "missing Lift algebra when using Lift" do
      computation = Lift.lift(State.get())

      assert_raise ArgumentError, ~r/No algebra found.*Lift/, fn ->
        HeftyRun.run(
          computation,
          [Catch.Algebra],  # Missing Lift.Algebra
          [State.Handler],
          %{State.Handler => 42}
        )
      end
    end
  end
end
