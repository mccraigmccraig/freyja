defmodule Skuld.Comp.Throw do
  @moduledoc "Error result that Catch recognizes"
  defstruct [:error]

  defimpl Skuld.Comp.ISentinel do
    # Throw goes through leave_scope so Catch can intercept it
    def run(result, env), do: env.leave_scope.(result, env)

    def run!(%Skuld.Comp.Throw{error: error}) do
      raise "Computation threw: #{inspect(error)}"
    end

    def sentinel?(_), do: true

    def get_resume(_), do: nil

    def with_resume(throw, _new_resume), do: throw

    def serializable_payload(%Skuld.Comp.Throw{error: error}) do
      %{error: error}
    end
  end
end
