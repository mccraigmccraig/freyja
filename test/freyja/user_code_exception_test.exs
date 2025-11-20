defmodule Freyja.UserCodeExceptionTest do
  use ExUnit.Case

  # Tests automatic exception conversion: when user code raises an exception,
  # it's caught and converted to a Throw effect (see freer/impl.ex handle_continuation_exception)

  import Freyja.Con
  import Freyja.HeftyMacro

  alias Freyja.Effects.Throw
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.Effects.Reader
  alias Freyja.Effects.Catch
  alias Freyja.Effects.Lift
  alias Freyja.Run
  alias Freyja.Hefty

  defmodule Examples do
    import Freyja.Con
    import Freyja.HeftyMacro

    defcon div_by_zero, [State] do
      x <- State.get()
      # This will raise ArithmeticError
      y <- return(Kernel.div(x, 0))
      _ <- State.put(y)
      return(y)
    end

    defcon map_fetch_missing, [Reader] do
      config <- Reader.ask()
      # This will raise KeyError
      value <- return(Map.fetch!(config, :nonexistent))
      return(value)
    end

    defcon function_clause_error, [State] do
      x <- State.get()
      # This will raise FunctionClauseError
      y <- return(only_atoms(x))
      return(y)
    end

    defp only_atoms(x) when is_atom(x), do: x

    defcon multiple_effects_with_error, [State, Writer] do
      _ <- Writer.tell("step 1")
      x <- State.get()
      _ <- Writer.tell("step 2")
      # This will raise
      y <- return(Kernel.div(10, x))
      _ <- Writer.tell("step 3")
      return(y)
    end

    defcon raising_with_state(initial_state), [State] do
      _ <- State.put(initial_state)
      x <- State.get()
      y <- return(Kernel.div(10, x))
      return(y)
    end

    # Migrated from defcon...catch_fx to defhefty with Catch
    defhefty caught_exception(initial_state) do
      res <-
        Freyja.Effects.Catch.catch_hefty(
          Lift.lift(raising_with_state(initial_state)),
          fn error ->
            # Error handler receives serialized exception
            Hefty.pure({:caught, error})
          end
        )

      return(res)
    end

    defcon successful_computation, [State] do
      x <- State.get()
      y <- return(x * 2)
      _ <- State.put(y)
      return(y)
    end
  end

  describe "user code exceptions with Throw handler" do
    test "ArithmeticError is caught and converted to Throw effect" do
      runner = Run.with_handlers(s: {State.Handler, 10}, e: Throw.Handler)
      outcome = Run.run(Examples.div_by_zero(), runner)

      assert %Freyja.RunOutcome{result: {:error, error_data}} = outcome

      # Verify error data structure
      assert is_map(error_data)
      assert error_data["type"] == "ArithmeticError"
      assert error_data["message"] == "bad argument in arithmetic expression"
      assert is_list(error_data["stacktrace"])
    end

    test "KeyError is caught and converted to Throw effect" do
      runner = Run.with_handlers(r: {Reader.Handler, %{foo: 1}}, e: Throw.Handler)
      outcome = Run.run(Examples.map_fetch_missing(), runner)

      assert %Freyja.RunOutcome{result: {:error, error_data}} = outcome

      assert is_map(error_data)
      assert error_data["type"] == "KeyError"
      assert String.contains?(error_data["message"], "key :nonexistent not found")
      assert is_list(error_data["stacktrace"])
    end

    test "FunctionClauseError is caught and converted to Throw effect" do
      runner = Run.with_handlers(s: {State.Handler, 123}, e: Throw.Handler)
      outcome = Run.run(Examples.function_clause_error(), runner)

      assert %Freyja.RunOutcome{result: {:error, error_data}} = outcome

      assert is_map(error_data)
      assert error_data["type"] == "FunctionClauseError"
      assert String.contains?(error_data["message"], "no function clause matching")
    end

    test "exceptions preserve state up to the point of error" do
      runner = Run.with_handlers(s: {State.Handler, 0}, w: {Writer.Handler, []}, e: Throw.Handler)
      outcome = Run.run(Examples.multiple_effects_with_error(), runner)

      assert %Freyja.RunOutcome{result: {:error, _error_data}} = outcome

      # State before error should be preserved
      assert outcome.outputs.s == 0

      # Writer logs up to the error should be preserved
      assert outcome.outputs.w == ["step 2", "step 1"]
    end

    test "exceptions can be caught and handled" do
      algebras = [Catch.Algebra, Lift.Algebra]
      handlers = [State.Handler, Throw.Handler]
      initial_states = %{State.Handler => 0}

      outcome = Hefty.Run.run(Examples.caught_exception(0), algebras, handlers, initial_states)

      assert %Freyja.RunOutcome{result: {:ok, {:caught, error_data}}} = outcome

      # Verify the caught error is the serialized exception
      assert is_map(error_data)
      assert error_data["type"] == "ArithmeticError"
      assert error_data["message"] == "bad argument in arithmetic expression"
    end

    test "successful computations still work" do
      runner = Run.with_handlers(s: {State.Handler, 5}, e: Throw.Handler)
      outcome = Run.run(Examples.successful_computation(), runner)

      assert %Freyja.RunOutcome{result: {:ok, 10}} = outcome
      assert outcome.outputs.s == 10
    end

    test "error data is JSON serializable" do
      runner = Run.with_handlers(s: {State.Handler, 10}, e: Throw.Handler)
      outcome = Run.run(Examples.div_by_zero(), runner)

      assert %Freyja.RunOutcome{result: {:error, error_data}} = outcome

      # Should be able to encode and decode
      assert {:ok, json} = Jason.encode(error_data)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["type"] == "ArithmeticError"
    end

    test "stacktrace contains relevant frames" do
      runner = Run.with_handlers(s: {State.Handler, 10}, e: Throw.Handler)
      outcome = Run.run(Examples.div_by_zero(), runner)

      assert %Freyja.RunOutcome{result: {:error, error_data}} = outcome

      # Should have stacktrace frames
      assert length(error_data["stacktrace"]) > 0

      # Should include the :erlang.div call
      assert Enum.any?(error_data["stacktrace"], fn frame ->
        String.contains?(frame["module"], "erlang") &&
          String.contains?(frame["function"], "div")
      end)
    end
  end

  describe "user code exceptions without Throw handler" do
    test "ArithmeticError causes unhandled Throw effect when no Throw handler present" do
      runner = Run.with_handlers(s: {State.Handler, 10})

      # Without Throw handler, the Throw effect will be unhandled and raise ArgumentError
      exception = assert_raise ArgumentError, fn ->
        Run.run(Examples.div_by_zero(), runner)
      end

      # The exception message should contain the original error details
      assert String.contains?(exception.message, "no handler for effect")
      assert String.contains?(exception.message, "ArithmeticError")
      assert String.contains?(exception.message, "bad argument in arithmetic expression")
    end

    test "KeyError causes unhandled Throw effect when no Throw handler present" do
      runner = Run.with_handlers(r: {Reader.Handler, %{foo: 1}})

      exception = assert_raise ArgumentError, fn ->
        Run.run(Examples.map_fetch_missing(), runner)
      end

      # The exception message should contain the original error details
      assert String.contains?(exception.message, "no handler for effect")
      assert String.contains?(exception.message, "KeyError")
      assert String.contains?(exception.message, "key :nonexistent not found")
    end

    test "successful computations work without Throw handler" do
      runner = Run.with_handlers(s: {State.Handler, 5})
      outcome = Run.run(Examples.successful_computation(), runner)

      assert %Freyja.RunOutcome{result: 10} = outcome
      assert outcome.outputs.s == 10
    end
  end

  describe "nested exception handling" do
    defmodule NestedExamples do
      import Freyja.Con
      import Freyja.HeftyMacro

      defcon inner_computation_with_state(initial_state), [State] do
        _ <- State.put(initial_state)
        x <- State.get()
        # Inner computation raises
        y <- return(Kernel.div(10, x))
        return(y)
      end

      # Migrated to defhefty with Catch
      defhefty outer_catches_inner(initial_state) do
        res <-
          Freyja.Effects.Catch.catch_hefty(
            Lift.lift(inner_computation_with_state(initial_state)),
            fn error ->
              # Outer catches and transforms
              Hefty.pure({:outer_caught, error})
            end
          )

        return(res)
      end

      defcon nested_no_catch_inner, [State] do
        x <- State.get()
        y <- return(Kernel.div(10, x))
        return(y)
      end

      defcon nested_no_catch, [State] do
        inner <- nested_no_catch_inner()
        return({:result, inner})
      end
    end

    test "outer catch can handle inner exception" do
      algebras = [Catch.Algebra, Lift.Algebra]
      handlers = [State.Handler, Throw.Handler]
      initial_states = %{State.Handler => 0}

      outcome = Hefty.Run.run(NestedExamples.outer_catches_inner(0), algebras, handlers, initial_states)

      assert %Freyja.RunOutcome{result: {:ok, {:outer_caught, error_data}}} = outcome
      assert is_map(error_data)
      assert error_data["type"] == "ArithmeticError"
    end

    test "exception propagates from nested computation" do
      runner = Run.with_handlers(s: {State.Handler, 0}, e: Throw.Handler)
      outcome = Run.run(NestedExamples.nested_no_catch(), runner)

      assert %Freyja.RunOutcome{result: {:error, error_data}} = outcome
      assert is_map(error_data)
      assert error_data["type"] == "ArithmeticError"
    end
  end
end
