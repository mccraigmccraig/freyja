defmodule Freyja.Run.SerializableResult do
  @moduledoc """
  Wrapper that normalizes common Freyja result shapes into JSON-friendly data.

  - If the value is a tuple whose first element is an atom (e.g. `{:ok, value}`),
    it is captured as `%SerializableResult{kind: :tuple, tuple_tag: :ok, tuple_args: [...]}`.
  - Any other value is stored verbatim under `value`.

  Use `wrap/1` before serialization and `unwrap/1` after deserialization to
  preserve the original Elixir shape.
  """

  defstruct kind: :value,
            tuple_tag: nil,
            tuple_args: nil,
            value: nil

  @type tuple_kind :: {atom, any}
  @type t :: %__MODULE__{
          kind: :tuple | :value,
          tuple_tag: atom | nil,
          tuple_args: [any] | nil,
          value: any
        }

  @doc """
  Wraps a value into a `SerializableResult`.

  Tuples whose first element is an atom are stored as tagged tuples so they can
  round-trip cleanly through JSON encoders.
  """
  @spec wrap(any) :: t
  def wrap(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    case elem(tuple, 0) do
      tag when is_atom(tag) ->
        [_ | args] = Tuple.to_list(tuple)

        %__MODULE__{
          kind: :tuple,
          tuple_tag: tag,
          tuple_args: args
        }

      _ ->
        wrap_any(tuple)
    end
  end

  def wrap(value), do: wrap_any(value)

  defp wrap_any(value) do
    %__MODULE__{
      kind: :value,
      value: value
    }
  end

  @doc """
  Restores the original Elixir value that was wrapped.
  """
  @spec unwrap(t | nil) :: any
  def unwrap(%__MODULE__{kind: :tuple, tuple_tag: tag, tuple_args: args}) do
    [tag | args]
    |> List.to_tuple()
  end

  def unwrap(%__MODULE__{kind: :value, value: value}), do: value
  def unwrap(nil), do: nil

  def from_json(map) when is_map(map) do
    case map["kind"] || map[:kind] do
      kind when kind in ["tuple", :tuple] ->
        args = map["tuple_args"] || map[:tuple_args] || []
        tag = normalize_tag(map["tuple_tag"] || map[:tuple_tag])

        wrap(List.to_tuple([tag | args]))

      kind when kind in ["value", :value] ->
        wrap(map["value"] || map[:value])

      _ ->
        map
    end
  end

  defp normalize_tag(tag) when is_atom(tag), do: tag
  defp normalize_tag(tag) when is_binary(tag), do: String.to_existing_atom(tag)

  defimpl Jason.Encoder do
    def encode(value, opts) do
      value
      |> Map.from_struct()
      |> Map.put(:__struct__, __MODULE__)
      |> Jason.Encode.map(opts)
    end
  end
end
