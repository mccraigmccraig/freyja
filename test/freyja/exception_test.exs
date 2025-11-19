defmodule Freyja.ExceptionTest do
  use ExUnit.Case

  alias Freyja.Exception, as: FException

  describe "to_serializable/3" do
    test "converts ArithmeticError to serializable map" do
      exception = %ArithmeticError{message: "bad argument in arithmetic expression"}

      stacktrace = [
        {MyModule, :my_function, 2, [file: ~c"lib/my_module.ex", line: 42]},
        {:erlang, :div, [10, 0], []}
      ]

      result = FException.to_serializable(exception, stacktrace)

      assert result["type"] == "ArithmeticError"
      assert result["message"] == "bad argument in arithmetic expression"
      assert is_list(result["stacktrace"])
      assert length(result["stacktrace"]) == 2
    end

    test "converts ArgumentError to serializable map" do
      exception = %ArgumentError{message: "invalid argument"}
      stacktrace = []

      result = FException.to_serializable(exception, stacktrace)

      assert result["type"] == "ArgumentError"
      assert result["message"] == "invalid argument"
      assert result["stacktrace"] == []
    end

    test "formats stacktrace with arity (integer)" do
      exception = %RuntimeError{message: "test"}

      stacktrace = [
        {MyModule, :my_function, 2, [file: ~c"lib/my_module.ex", line: 42]}
      ]

      result = FException.to_serializable(exception, stacktrace)

      [frame] = result["stacktrace"]
      assert frame["module"] == "MyModule"
      assert frame["function"] == "my_function/2"
      assert frame["file"] == "lib/my_module.ex"
      assert frame["line"] == 42
    end

    test "formats stacktrace with args (list)" do
      exception = %RuntimeError{message: "test"}

      stacktrace = [
        {MyModule, :my_function, [:arg1, :arg2], [file: ~c"lib/my_module.ex", line: 10]}
      ]

      result = FException.to_serializable(exception, stacktrace)

      [frame] = result["stacktrace"]
      assert frame["module"] == "MyModule"
      assert frame["function"] == "my_function/2"
      assert frame["file"] == "lib/my_module.ex"
      assert frame["line"] == 10
    end

    test "handles erlang module stacktrace entries" do
      exception = %ArithmeticError{message: "test"}

      stacktrace = [
        {:erlang, :div, [10, 0], []}
      ]

      result = FException.to_serializable(exception, stacktrace)

      [frame] = result["stacktrace"]
      assert frame["module"] == ":erlang"
      assert frame["function"] == "div/2"
      assert frame["file"] == nil
      assert frame["line"] == nil
    end

    test "limits stacktrace to specified limit" do
      exception = %RuntimeError{message: "test"}

      stacktrace =
        Enum.map(1..20, fn i ->
          {MyModule, :function, i, [file: ~c"test.ex", line: i]}
        end)

      result = FException.to_serializable(exception, stacktrace, stacktrace_limit: 5)

      assert length(result["stacktrace"]) == 5
    end

    test "uses default stacktrace limit of 10" do
      exception = %RuntimeError{message: "test"}

      stacktrace =
        Enum.map(1..20, fn i ->
          {MyModule, :function, i, [file: ~c"test.ex", line: i]}
        end)

      result = FException.to_serializable(exception, stacktrace)

      assert length(result["stacktrace"]) == 10
    end

    test "can exclude stacktrace with include_stacktrace: false" do
      exception = %RuntimeError{message: "test"}

      stacktrace = [
        {MyModule, :my_function, 2, [file: ~c"lib/my_module.ex", line: 42]}
      ]

      result = FException.to_serializable(exception, stacktrace, include_stacktrace: false)

      assert result["type"] == "RuntimeError"
      assert result["message"] == "test"
      refute Map.has_key?(result, "stacktrace")
    end

    test "handles missing file and line in stacktrace" do
      exception = %RuntimeError{message: "test"}

      stacktrace = [
        {MyModule, :my_function, 2, []}
      ]

      result = FException.to_serializable(exception, stacktrace)

      [frame] = result["stacktrace"]
      assert frame["file"] == nil
      assert frame["line"] == nil
    end

    test "result is JSON serializable" do
      exception = %ArgumentError{message: "test error"}

      stacktrace = [
        {MyModule, :test, 1, [file: ~c"test.ex", line: 10]}
      ]

      result = FException.to_serializable(exception, stacktrace)

      assert {:ok, json} = Jason.encode(result)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["type"] == "ArgumentError"
      assert decoded["message"] == "test error"
    end

    test "handles exceptions with custom struct fields" do
      # Some exceptions have additional fields beyond :message
      exception = %KeyError{key: :foo, term: %{}}
      stacktrace = []

      result = FException.to_serializable(exception, stacktrace)

      assert result["type"] == "KeyError"
      # Exception.message/1 will format it appropriately
      assert is_binary(result["message"])
    end
  end

  describe "format_compact/1" do
    test "formats ArithmeticError compactly" do
      exception = %ArithmeticError{message: "bad argument in arithmetic expression"}

      result = FException.format_compact(exception)

      assert result == "ArithmeticError: bad argument in arithmetic expression"
    end

    test "formats ArgumentError compactly" do
      exception = %ArgumentError{message: "invalid argument"}

      result = FException.format_compact(exception)

      assert result == "ArgumentError: invalid argument"
    end

    test "removes Elixir. prefix for readability" do
      exception = %RuntimeError{message: "test"}

      result = FException.format_compact(exception)

      # Should not have "Elixir." prefix
      refute String.starts_with?(result, "Elixir.")
      assert result == "RuntimeError: test"
    end

    test "formats KeyError with full message" do
      exception = %KeyError{key: :foo, term: %{bar: 1}}

      result = FException.format_compact(exception)

      assert String.starts_with?(result, "KeyError:")
      assert is_binary(result)
    end
  end

  describe "real exceptions" do
    test "captures real ArithmeticError from division by zero" do
      result =
        try do
          Kernel.div(1, 0)
        rescue
          e ->
            FException.to_serializable(e, __STACKTRACE__, stacktrace_limit: 3)
        end

      assert result["type"] == "ArithmeticError"
      assert result["message"] == "bad argument in arithmetic expression"
      assert is_list(result["stacktrace"])
      # Should have at least the :erlang.div call
      assert Enum.any?(result["stacktrace"], fn frame ->
               String.contains?(frame["module"], "erlang") &&
                 String.contains?(frame["function"], "div")
             end)
    end

    test "captures real ArgumentError" do
      result =
        try do
          raise ArgumentError, "test message"
        rescue
          e ->
            FException.to_serializable(e, __STACKTRACE__, stacktrace_limit: 3)
        end

      assert result["type"] == "ArgumentError"
      assert result["message"] == "test message"
      assert is_list(result["stacktrace"])
      assert length(result["stacktrace"]) <= 3
    end

    test "captures real FunctionClauseError" do
      defmodule TestModule do
        def only_atoms(x) when is_atom(x), do: x
      end

      result =
        try do
          TestModule.only_atoms(123)
        rescue
          e ->
            FException.to_serializable(e, __STACKTRACE__, stacktrace_limit: 3)
        end

      assert result["type"] == "FunctionClauseError"
      assert String.contains?(result["message"], "no function clause matching")
      assert is_list(result["stacktrace"])
    end

    test "real exception round-trips through JSON" do
      result =
        try do
          Map.fetch!(%{}, :nonexistent)
        rescue
          e ->
            FException.to_serializable(e, __STACKTRACE__)
        end

      # Encode to JSON
      assert {:ok, json} = Jason.encode(result)

      # Decode from JSON
      assert {:ok, decoded} = Jason.decode(json)

      # Verify structure is preserved
      assert decoded["type"] == result["type"]
      assert decoded["message"] == result["message"]
      assert length(decoded["stacktrace"]) == length(result["stacktrace"])
    end
  end
end
