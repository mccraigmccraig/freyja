defmodule Freyja.Freer.Exception do
  @moduledoc """
  Utilities for converting Elixir exceptions to serializable error representations.

  Used during first-order effect interpretation (Freer) to handle exceptions that
  occur in user code. Provides standard formats for representing exceptions as
  JSON-serializable maps, suitable for logging, replay, and debugging.
  """

  @doc """
  Convert an exception and stacktrace to a serializable map.

  Returns a map with the following structure:
  ```elixir
  %{
    "type" => "Elixir.ArithmeticError",
    "message" => "bad argument in arithmetic expression",
    "stacktrace" => [
      %{
        "module" => "MyModule",
        "function" => "my_function/2",
        "file" => "lib/my_module.ex",
        "line" => 42
      },
      ...
    ]
  }
  ```

  ## Options
  - `:stacktrace_limit` - Maximum number of stacktrace frames to include (default: 10)
  - `:include_stacktrace` - Whether to include stacktrace at all (default: true)

  ## Examples

      try do
        raise ArgumentError, "invalid input"
      rescue
        e ->
          Freyja.Freer.Exception.to_serializable(e, __STACKTRACE__)
          #=> %{"type" => "Elixir.ArgumentError", "message" => "invalid input", ...}
      end
  """
  @spec to_serializable(Exception.t(), Exception.stacktrace(), keyword()) :: map()
  def to_serializable(exception, stacktrace \\ [], opts \\ []) do
    stacktrace_limit = Keyword.get(opts, :stacktrace_limit, 10)
    include_stacktrace = Keyword.get(opts, :include_stacktrace, true)

    base = %{
      "type" => exception_type_to_string(exception),
      "message" => Exception.message(exception)
    }

    if include_stacktrace do
      Map.put(base, "stacktrace", format_stacktrace(stacktrace, stacktrace_limit))
    else
      base
    end
  end

  @doc """
  Format an exception as a compact string for display.

  ## Examples

      iex> exception = %ArgumentError{message: "test"}
      iex> Freyja.Freer.Exception.format_compact(exception)
      "ArgumentError: test"
  """
  @spec format_compact(Exception.t()) :: String.t()
  def format_compact(exception) do
    type = exception_type_to_string(exception)
    message = Exception.message(exception)

    # Remove "Elixir." prefix for readability
    type = String.replace_prefix(type, "Elixir.", "")

    "#{type}: #{message}"
  end

  # Convert exception type to string, handling both Elixir and Erlang exceptions
  defp exception_type_to_string(exception) do
    case exception.__struct__ do
      mod when is_atom(mod) ->
        inspect(mod)

      other ->
        inspect(other)
    end
  end

  # Format stacktrace entries into serializable maps
  defp format_stacktrace(stacktrace, limit) do
    stacktrace
    |> Enum.take(limit)
    |> Enum.map(&format_stacktrace_entry/1)
  end

  # Format a single stacktrace entry
  # Handles both {mod, fun, arity, location} and {mod, fun, args, location} formats
  defp format_stacktrace_entry({mod, fun, arity, location}) when is_integer(arity) do
    %{
      "module" => inspect(mod),
      "function" => "#{fun}/#{arity}",
      "file" => location |> Keyword.get(:file) |> to_string_safe(),
      "line" => Keyword.get(location, :line)
    }
  end

  defp format_stacktrace_entry({mod, fun, args, location}) when is_list(args) do
    %{
      "module" => inspect(mod),
      "function" => "#{fun}/#{length(args)}",
      "file" => location |> Keyword.get(:file) |> to_string_safe(),
      "line" => Keyword.get(location, :line)
    }
  end

  # Fallback for unexpected formats
  defp format_stacktrace_entry(entry) do
    %{"raw" => inspect(entry)}
  end

  # Safely convert charlist/string to string, handling nil
  defp to_string_safe(nil), do: nil
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_list(value), do: List.to_string(value)
  defp to_string_safe(value), do: inspect(value)
end
