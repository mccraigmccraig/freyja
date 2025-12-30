defmodule Skuld.Comp.Suspend do
  @moduledoc "Sentinel that bypasses leave-scope chain"
  defstruct [:value, :resume]
  # resume :: (input -> {result, env})

  defimpl Skuld.Comp.ISentinel do
    def run(suspend, env), do: {suspend, env}

    def run!(%Skuld.Comp.Suspend{}) do
      raise "Computation suspended unexpectedly"
    end
  end
end
