defmodule Freyja.Run.SerializableValueTest do
  use ExUnit.Case, async: true

  alias Freyja.Run.SerializableValue

  test "wrap/unwrap preserves {:atom, ...} tuples" do
    original = {:error, :timeout, 5}

    wrapped = SerializableValue.wrap(original)
    assert wrapped.kind == :tuple
    assert wrapped.tuple_tag == :error
    assert wrapped.tuple_args == [:timeout, 5]

    assert SerializableValue.unwrap(wrapped) == original
  end

  test "wrap/unwrap passes through other values" do
    original = %{result: {:ok, 1}, foo: "bar"}

    wrapped = SerializableValue.wrap(original)
    assert wrapped.kind == :value
    assert wrapped.value == original

    assert SerializableValue.unwrap(wrapped) == original
  end

  test "wrap falls back to value when tuple head is not atom" do
    tuple = {1, 2, 3}

    wrapped = SerializableValue.wrap(tuple)
    assert wrapped.kind == :value
    assert SerializableValue.unwrap(wrapped) == tuple
  end
end
