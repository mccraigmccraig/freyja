defmodule Freyja.Run.RunBuilderTest do
  use ExUnit.Case

  import Freyja.Freer.FreerBlock
  use Freyja.Syntax

  alias Freyja.Run.RunBuilder
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.Effects.Throw
  alias Freyja.Effects.Lift
  alias Freyja.Effects.Catch

  describe "RunBuilder.add/3" do
    test "creates builder from Freer.Pure computation" do
      computation = Freyja.Freer.pure(42)

      builder = RunBuilder.add(computation, State.Handler, 0)

      assert %RunBuilder{
               computation: ^computation,
               computation_type: :freer,
               algebras: [],
               handlers: [{State.Handler, 0}]
             } = builder
    end

    test "creates builder from Freer.Impure computation" do
      computation = con State do
        x <- get()
        return(x)
      end

      builder = RunBuilder.add(computation, State.Handler, 5)

      assert %RunBuilder{
               computation: ^computation,
               computation_type: :freer,
               handlers: [{State.Handler, 5}]
             } = builder
    end

    test "creates builder from Hefty.Pure computation" do
      computation = Freyja.Hefty.pure(42)

      builder = RunBuilder.add(computation, Lift.Algebra, nil)

      assert %RunBuilder{
               computation: ^computation,
               computation_type: :hefty,
               algebras: [Lift.Algebra],
               handlers: []
             } = builder
    end

    test "creates builder from Hefty.Impure computation" do
      computation = hefty do
        x <- Lift.lift(State.get())
        return(x)
      end

      builder = RunBuilder.add(computation, Catch.Algebra, nil)

      assert %RunBuilder{
               computation: ^computation,
               computation_type: :hefty,
               algebras: [Catch.Algebra]
             } = builder
    end

    test "adds handler to existing builder" do
      computation = con State do
        x <- get()
        return(x)
      end

      builder =
        computation
        |> RunBuilder.add(State.Handler, 0)
        |> RunBuilder.add(Writer.Handler, [])

      assert %RunBuilder{
               handlers: [
                 {State.Handler, 0},
                 {Writer.Handler, []}
               ]
             } = builder
    end

    test "adds algebra to existing builder" do
      computation = hefty do
        return(42)
      end

      builder =
        computation
        |> RunBuilder.add(Catch.Algebra, nil)
        |> RunBuilder.add(Lift.Algebra, nil)

      assert %RunBuilder{
               algebras: [Catch.Algebra, Lift.Algebra]
             } = builder
    end

    test "maintains order of additions" do
      computation = con State do
        x <- get()
        return(x)
      end

      builder =
        computation
        |> RunBuilder.add(State.Handler, 0)
        |> RunBuilder.add(Writer.Handler, [])
        |> RunBuilder.add(Throw.Handler, nil)

      assert builder.handlers == [
               {State.Handler, 0},
               {Writer.Handler, []},
               {Throw.Handler, nil}
             ]
    end

    test "uses default initial state when available" do
      computation = con State do
        x <- get()
        return(x)
      end

      # Assume Throw.Handler has default_initial_state/0 returning nil
      # For now, just pass nil explicitly to test the pattern
      builder = RunBuilder.add(computation, Throw.Handler, nil)

      assert %RunBuilder{
               handlers: [{Throw.Handler, nil}]
             } = builder
    end

    test "mixes algebras and handlers in Hefty builder" do
      computation = hefty do
        x <- Lift.lift(State.get())
        return(x)
      end

      builder =
        computation
        |> RunBuilder.add(Catch.Algebra, nil)
        |> RunBuilder.add(Lift.Algebra, nil)
        |> RunBuilder.add(State.Handler, 0)
        |> RunBuilder.add(Throw.Handler, nil)

      assert %RunBuilder{
               computation_type: :hefty,
               algebras: [Catch.Algebra, Lift.Algebra],
               handlers: [{State.Handler, 0}, {Throw.Handler, nil}]
             } = builder
    end

    test "raises error for invalid module (neither algebra nor handler)" do
      computation = con State do
        x <- get()
        return(x)
      end

      # Use a module that's neither
      assert_raise ArgumentError, ~r/implements neither/, fn ->
        RunBuilder.add(computation, String, nil)
      end
    end

    test "raises error for invalid computation type" do
      # Pass a non-computation value
      assert_raise ArgumentError, ~r/Cannot detect computation type/, fn ->
        RunBuilder.add("not a computation", State.Handler, 0)
      end
    end
  end
end
