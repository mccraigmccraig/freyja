defmodule Freyja.Run.SerializableResult do
  @moduledoc """
  Wrapper that normalizes common Freyja result shapes into JSON-friendly data.

  - If the value is a tuple whose first element is an atom (e.g. `{:ok, value}`),
    it is captured as `%SerializableResult{kind: :tuple, tuple_tag: :ok, tuple_args: [...]}`.
  - Any other value is stored verbatim under `value`.

  Use `wrap/1` before serialization and `unwrap/1` after deserialization to
  preserve the original Elixir shape.
  """

  alias Freyja.Run.SerializableStruct

  @type_key "__freyja_type__"
  @atom_marker "__freyja_atom__"

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
        args =
          (map["tuple_args"] || map[:tuple_args] || [])
          |> Enum.map(&decode_arg/1)

        tag = decode_atom(map["tuple_tag"] || map[:tuple_tag])

        %__MODULE__{
          kind: :tuple,
          tuple_tag: tag,
          tuple_args: args
        }

      kind when kind in ["value", :value] ->
        %__MODULE__{
          kind: :value,
          value: decode_arg(map["value"] || map[:value])
        }

      _ ->
        map
    end
  end

  defp decode_atom(tag) when is_atom(tag), do: tag

  defp decode_atom(%{@type_key => @atom_marker, "value" => name}), do: safe_to_existing_atom(name)
  defp decode_atom(%{@type_key => @atom_marker, value: name}), do: safe_to_existing_atom(name)

  defp decode_atom(tag) when is_binary(tag), do: safe_to_existing_atom(tag)

  defp decode_arg(%{@type_key => @atom_marker} = marker), do: decode_atom(marker)

  defp decode_arg(%{"__struct__" => _} = map), do: SerializableStruct.decode(map)
  defp decode_arg(%{__struct__: _} = map), do: SerializableStruct.decode(map)

  defp decode_arg(map) when is_map(map), do: map

  defp decode_arg(list) when is_list(list), do: Enum.map(list, &decode_arg/1)

  defp decode_arg(value), do: value

  defp safe_to_existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  def to_json_map(%__MODULE__{kind: :tuple, tuple_tag: tag, tuple_args: args}) do
    %{
      __struct__: __MODULE__,
      kind: :tuple,
      tuple_tag: encode_atom(tag),
      tuple_args: Enum.map(args, &encode_arg/1)
    }
  end

  def to_json_map(%__MODULE__{kind: :value, value: value}) do
    %{
      __struct__: __MODULE__,
      kind: :value,
      value: encode_arg(value)
    }
  end

  defp encode_atom(atom) when is_atom(atom), do: encode_arg(atom)

  defp encode_arg(value) when is_atom(value) do
    %{@type_key => @atom_marker, "value" => Atom.to_string(value)}
  end

  defp encode_arg(%_{} = struct), do: SerializableStruct.encode(struct)

  defp encode_arg(list) when is_list(list), do: Enum.map(list, &encode_arg/1)

  defp encode_arg(map) when is_map(map), do: map

  defp encode_arg(value), do: value

  defimpl Jason.Encoder do
    def encode(value, opts) do
      value
      |> Freyja.Run.SerializableResult.to_json_map()
      |> Jason.Encode.map(opts)
    end
  end
end
