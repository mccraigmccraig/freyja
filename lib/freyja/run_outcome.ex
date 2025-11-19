defmodule Freyja.RunOutcome do
  @moduledoc """
  Unified run outcome envelope for Freyja interpreters.

  - `result`: the primary computation result, which can be:
    - Any value for successful completion
    - `{:error, reason}` for errors
    - `{:suspend, value, continuation}` for suspended coroutines
  - `outputs`: flat map for effect-specific outputs (e.g., state, writer, logs)
  """

  alias Freyja.Run.RunState

  defstruct result: nil, outputs: %{}, run_state: nil

  @type t :: %__MODULE__{result: any, outputs: map(), run_state: RunState.t()}

  @spec new(any, map(), RunState.t()) :: t
  def new(result, outputs, %RunState{} = run_state) when is_map(outputs),
    do: %__MODULE__{result: result, outputs: outputs, run_state: run_state}
end
