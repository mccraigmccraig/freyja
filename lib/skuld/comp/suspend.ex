defmodule Skuld.Comp.Suspend do
  @moduledoc "Sentinel that bypasses leave-scope chain"
  defstruct [:value, :resume]
  # resume :: (input -> {result, env})

  defimpl Skuld.Comp.ISentinel do
    def run(suspend, env), do: {suspend, env}

    def run!(%Skuld.Comp.Suspend{}) do
      raise "Computation suspended unexpectedly"
    end

    def sentinel?(_), do: true

    def get_resume(%Skuld.Comp.Suspend{resume: resume}), do: resume

    def with_resume(suspend, new_resume) do
      %Skuld.Comp.Suspend{suspend | resume: new_resume}
    end

    def serializable_payload(%Skuld.Comp.Suspend{value: value}) do
      %{yielded: value}
    end
  end
end
