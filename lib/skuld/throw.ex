defmodule Skuld.Throw do
  @moduledoc "Error result that Catch recognizes"
  defstruct [:error]

  defimpl Skuld.ISentinel do
    # Throw goes through leave_scope so Catch can intercept it
    def run(result, env), do: env.leave_scope.(result, env)

    def run!(%Skuld.Throw{error: error}) do
      raise "Computation threw: #{inspect(error)}"
    end
  end
end
