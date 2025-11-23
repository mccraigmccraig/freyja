defmodule Freyja.Run.SerializableStructTest do
  use ExUnit.Case, async: true

  alias Freyja.Run.SerializableStruct

  defmodule Sample do
    defstruct [:foo, bar: 10]
  end

  test "encode injects __struct__ metadata" do
    encoded = SerializableStruct.encode(%Sample{foo: :ok})

    assert Map.get(encoded, :__struct__) == Sample
    assert Map.get(encoded, :foo) == :ok
    assert Map.get(encoded, :bar) == 10
  end

  test "decode reconstructs struct when __struct__ provided as string" do
    encoded = %{
      "__struct__" => Atom.to_string(Sample),
      "foo" => 42
    }

    assert SerializableStruct.decode(encoded) == %Sample{foo: 42}
  end

  test "decode falls back to map when metadata missing" do
    map = %{"foo" => "bar"}
    assert SerializableStruct.decode(map) == map
  end
end
