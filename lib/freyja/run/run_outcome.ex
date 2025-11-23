defmodule Freyja.Run.RunOutcome do
  @moduledoc """
  Unified run outcome envelope for Freyja interpreters.

  - `result`: the primary computation result, which can be:
    - Any value for successful completion
    - `{:error, reason}` for errors
    - `{:suspend, value, continuation}` for suspended coroutines
  - `outputs`: flat map for effect-specific outputs (e.g., state, writer, logs)
  """

  alias Freyja.Run.RunState
  alias Freyja.Run.SerializableResult
  alias Freyja.Run.SerializableStruct

  defstruct result: nil, outputs: %{}, run_state: nil

  @type t :: %__MODULE__{result: any, outputs: map(), run_state: RunState.t()}

  @spec new(any, map(), RunState.t()) :: t
  def new(result, outputs, %RunState{} = run_state) when is_map(outputs),
    do: %__MODULE__{result: result, outputs: outputs, run_state: run_state}

  def from_json(map) when is_map(map) do
    %__MODULE__{
      result:
        map["result"]
        |> SerializableResult.from_json()
        |> SerializableResult.unwrap(),
      outputs: decode_outputs(map["outputs"] || %{}),
      run_state: nil
    }
  end

  defp decode_outputs(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      atom_key = key_to_existing_atom(key)
      decoded = SerializableStruct.decode(value)
      Map.put(acc, atom_key, decoded)
    end)
  end

  defp key_to_existing_atom(key) when is_atom(key), do: key
  defp key_to_existing_atom(key) when is_binary(key), do: String.to_existing_atom(key)

  defimpl Jason.Encoder do
    def encode(%{result: result, outputs: outputs}, opts) do
      json_exports =
        outputs
        |> Enum.map(fn {key, value} ->
          encoded =
            case value do
              %_{} -> SerializableStruct.encode(value)
              _ -> value
            end

          {key, encoded}
        end)
        |> Enum.into(%{})

      Jason.Encode.map(
        %{
          result: SerializableResult.wrap(result),
          outputs: json_exports
        },
        opts
      )
    end
  end
end
