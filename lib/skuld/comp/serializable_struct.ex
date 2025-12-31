defmodule Skuld.Comp.SerializableStruct do
  @moduledoc """
  Utilities for converting structs to/from JSON-friendly maps.

  Encoded structs include a `__struct__` field so they can be faithfully
  reconstructed after decoding (e.g., from `Jason.decode/1`). Keys are expected
  to already exist as atoms in the system to avoid dynamic atom creation.
  """

  @doc """
  Convert a struct into a map representation suitable for JSON encoding.
  """
  @spec encode(struct) :: map
  def encode(%module{} = value) when is_atom(module) do
    value
    |> Map.from_struct()
    |> Map.put("__struct__", Atom.to_string(module))
  end

  @doc """
  Reconstructs a struct from a decoded JSON map produced by `encode/1`.
  If the map doesn't include struct metadata, it is returned unchanged.
  """
  @spec decode(map) :: struct | map
  def decode(map) when is_map(map) do
    case fetch_struct_module(map) do
      {:ok, module} ->
        if function_exported?(module, :from_json, 1) do
          module.from_json(map)
        else
          attrs =
            map
            |> Map.delete("__struct__")
            |> Map.delete(:__struct__)
            |> Enum.reduce(%{}, fn {k, v}, acc ->
              Map.put(acc, key_to_existing_atom(k), v)
            end)

          struct(module, attrs)
        end

      :error ->
        map
    end
  end

  def decode(value), do: value

  defp fetch_struct_module(map) do
    case Map.get(map, "__struct__") || Map.get(map, :__struct__) do
      nil ->
        :error

      module when is_atom(module) ->
        ensure_loaded(module)

      struct_name when is_binary(struct_name) ->
        struct_name
        |> String.to_existing_atom()
        |> ensure_loaded()
    end
  rescue
    ArgumentError ->
      :error
  end

  defp ensure_loaded(module) do
    case Code.ensure_loaded(module) do
      {:module, _} -> {:ok, module}
      _ -> :error
    end
  end

  defp key_to_existing_atom(key) when is_atom(key), do: key

  defp key_to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  end
end
