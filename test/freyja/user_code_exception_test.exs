defmodule Freyja.UserCodeExceptionTest do
  use ExUnit.Case

  import Freyja.Con

  alias Freyja.Effects.Error
  alias Freyja.Effects.State
  alias Freyja.Effects.Writer
  alias Freyja.Effects.Reader
  alias Freyja.Run
  alias Freyja.ErrorResult
  alias Freyja.OkResult

  defmodule Examples do
    import Freyja.Con

    defcon div_by_zero, [State] do
      x <- get()
      # This will raise ArithmeticError
      y <- return(Kernel.div(x, 0))
      put(y)
      return(y)
    end

    defcon map_fetch_missing, [Reader] do
      config <- ask()
      # This will raise KeyError
      value <- return(Map.fetch!(config, :nonexistent))
      return(value)
    end

    defcon function_clause_error, [State] do
      x <- get()
      # This will raise FunctionClauseError
      y <- return(only_atoms(x))
      return(y)
    end

    defp only_atoms(x) when is_atom(x), do: x

    defcon multiple_effects_with_error, [State, Writer] do
      tell("step 1")
      x <- get()
      tell("step 2")
      # This will raise
      y <- return(Kernel.div(10, x))
      tell("step 3")
      return(y)
    end

    defcon caught_exception, [Error, State] do
      res <-
        catch_fx(
          con [Error, State] do
            x <- get()
            y <- return(Kernel.div(10, x))
            return(y)
          end,
          fn error ->
            # Error handler receives serialized exception
            return({:caught, error})
          end
        )

      return(res)
    end

    defcon successful_computation, [State] do
      x <- get()
      y <- return(x * 2)
      put(y)
      return(y)
    end
  end

  describe "user code exceptions with Error handler" do
    test "ArithmeticError is caught and converted to Error effect" do
      runner = Run.with_handlers(s: {State.Handler, 10}, e: Error.Handler)
      outcome = Run.run(Examples.div_by_zero(), runner)

      assert %Freyja.RunOutcome{result: %ErrorResult{error: error_data}} = outcome

      # Verify error data structure
      assert is_map(error_data)
      assert error_data["type"] == "ArithmeticError"
      assert error_data["message"] == "bad argument in arithmetic expression"
      assert is_list(error_data["stacktrace"])
    end

    test "KeyError is caught and converted to Error effect" do
      runner = Run.with_handlers(r: {Reader.Handler, %{foo: 1}}, e: Error.Handler)
      outcome = Run.run(Examples.map_fetch_missing(), runner)

      assert %Freyja.RunOutcome{result: %ErrorResult{error: error_data}} = outcome

      assert is_map(error_data)
      assert error_data["type"] == "KeyError"
      assert String.contains?(error_data["message"], "key :nonexistent not found")
      assert is_list(error_data["stacktrace"])
    end

    test "FunctionClauseError is caught and converted to Error effect" do
      runner = Run.with_handlers(s: {State.Handler, 123}, e: Error.Handler)
      outcome = Run.run(Examples.function_clause_error(), runner)

      assert %Freyja.RunOutcome{result: %ErrorResult{error: error_data}} = outcome

      assert is_map(error_data)
      assert error_data["type"] == "FunctionClauseError"
      assert String.contains?(error_data["message"], "no function clause matching")
    end

    test "exceptions preserve state up to the point of error" do
      runner = Run.with_handlers(s: {State.Handler, 0}, w: {Writer.Handler, []}, e: Error.Handler)
      outcome = Run.run(Examples.multiple_effects_with_error(), runner)

      assert %Freyja.RunOutcome{result: %ErrorResult{}} = outcome

      # State before error should be preserved
      assert outcome.outputs.s == 0

      # Writer logs up to the error should be preserved
      assert outcome.outputs.w == ["step 2", "step 1"]
    end

    test "exceptions can be caught and handled" do
      runner = Run.with_handlers(s: {State.Handler, 0}, e: Error.Handler)
      outcome = Run.run(Examples.caught_exception(), runner)

      assert %Freyja.RunOutcome{result: %OkResult{value: {:caught, error_data}}} = outcome

      # Verify the caught error is the serialized exception
      assert is_map(error_data)
      assert error_data["type"] == "ArithmeticError"
      assert error_data["message"] == "bad argument in arithmetic expression"
    end

    test "successful computations still work" do
      runner = Run.with_handlers(s: {State.Handler, 5}, e: Error.Handler)
      outcome = Run.run(Examples.successful_computation(), runner)

      assert %Freyja.RunOutcome{result: %OkResult{value: 10}} = outcome
      assert outcome.outputs.s == 10
    end

    test "error data is JSON serializable" do
      runner = Run.with_handlers(s: {State.Handler, 10}, e: Error.Handler)
      outcome = Run.run(Examples.div_by_zero(), runner)

      assert %Freyja.RunOutcome{result: %ErrorResult{error: error_data}} = outcome

      # Should be able to encode and decode
      assert {:ok, json} = Jason.encode(error_data)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["type"] == "ArithmeticError"
    end

    test "stacktrace contains relevant frames" do
      runner = Run.with_handlers(s: {State.Handler, 10}, e: Error.Handler)
      outcome = Run.run(Examples.div_by_zero(), runner)

      assert %Freyja.RunOutcome{result: %ErrorResult{error: error_data}} = outcome

      # Should have stacktrace frames
      assert length(error_data["stacktrace"]) > 0

      # Should include the :erlang.div call
      assert Enum.any?(error_data["stacktrace"], fn frame ->
        String.contains?(frame["module"], "erlang") &&
          String.contains?(frame["function"], "div")
      end)
    end
  end

  describe "user code exceptions without Error handler" do
    test "ArithmeticError causes unhandled Error effect when no Error handler present" do
      runner = Run.with_handlers(s: {State.Handler, 10})

      # Without Error handler, the Error effect will be unhandled and raise ArgumentError
      exception = assert_raise ArgumentError, fn ->
        Run.run(Examples.div_by_zero(), runner)
      end

      # The exception message should contain the original error details
      assert String.contains?(exception.message, "no handler for effect")
      assert String.contains?(exception.message, "ArithmeticError")
      assert String.contains?(exception.message, "bad argument in arithmetic expression")
    end

    test "KeyError causes unhandled Error effect when no Error handler present" do
      runner = Run.with_handlers(r: {Reader.Handler, %{foo: 1}})

      exception = assert_raise ArgumentError, fn ->
        Run.run(Examples.map_fetch_missing(), runner)
      end

      # The exception message should contain the original error details
      assert String.contains?(exception.message, "no handler for effect")
      assert String.contains?(exception.message, "KeyError")
      assert String.contains?(exception.message, "key :nonexistent not found")
    end

    test "successful computations work without Error handler" do
      runner = Run.with_handlers(s: {State.Handler, 5})
      outcome = Run.run(Examples.successful_computation(), runner)

      assert %Freyja.RunOutcome{result: %OkResult{value: 10}} = outcome
      assert outcome.outputs.s == 10
    end
  end

  describe "nested exception handling" do
    defmodule NestedExamples do
      import Freyja.Con

      defcon outer_catches_inner, [Error, State] do
        res <-
          catch_fx(
            con [Error, State] do
              x <- get()
              # Inner computation raises
              y <- return(Kernel.div(10, x))
              return(y)
            end,
            fn error ->
              # Outer catches and transforms
              return({:outer_caught, error})
            end
          )

        return(res)
      end

      defcon nested_no_catch, [Error, State] do
        inner <-
          con [Error, State] do
            x <- get()
            y <- return(Kernel.div(10, x))
            return(y)
          end

        return({:result, inner})
      end
    end

    test "outer catch can handle inner exception" do
      runner = Run.with_handlers(s: {State.Handler, 0}, e: Error.Handler)
      outcome = Run.run(NestedExamples.outer_catches_inner(), runner)

      assert %Freyja.RunOutcome{result: %OkResult{value: {:outer_caught, error_data}}} = outcome
      assert is_map(error_data)
      assert error_data["type"] == "ArithmeticError"
    end

    test "exception propagates from nested computation" do
      runner = Run.with_handlers(s: {State.Handler, 0}, e: Error.Handler)
      outcome = Run.run(NestedExamples.nested_no_catch(), runner)

      assert %Freyja.RunOutcome{result: %ErrorResult{error: error_data}} = outcome
      assert is_map(error_data)
      assert error_data["type"] == "ArithmeticError"
    end
  end
end
