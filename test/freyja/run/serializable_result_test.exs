defmodule Freyja.Run.SerializableResultTest do
  use ExUnit.Case, async: true

  alias Freyja.Run.SerializableResult

  test "wrap/unwrap preserves {:atom, ...} tuples" do
    original = {:error, :timeout, 5}

    wrapped = SerializableResult.wrap(original)
    assert wrapped.kind == :tuple
    assert wrapped.tuple_tag == :error
    assert wrapped.tuple_args == [:timeout, 5]

    assert SerializableResult.unwrap(wrapped) == original
  end

  test "wrap/unwrap passes through other values" do
    original = %{result: {:ok, 1}, foo: "bar"}

    wrapped = SerializableResult.wrap(original)
    assert wrapped.kind == :value
    assert wrapped.value == original

    assert SerializableResult.unwrap(wrapped) == original
  end

  test "wrap falls back to value when tuple head is not atom" do
    tuple = {1, 2, 3}

    wrapped = SerializableResult.wrap(tuple)
    assert wrapped.kind == :value
    assert SerializableResult.unwrap(wrapped) == tuple
  end

  test "encoded value round-trips via from_json" do
    wrapped = SerializableResult.wrap({:ok, 1})

    json =
      wrapped
      |> Jason.encode!()
      |> Jason.decode!()

    assert SerializableResult.from_json(json) |> SerializableResult.unwrap() == {:ok, 1}
  end

  test "functions inside tuple args encode as nil" do
    fun = fn -> :ok end
    wrapped = SerializableResult.wrap({:suspend, 42, fun})

    json =
      wrapped
      |> Jason.encode!()
      |> Jason.decode!()

    decoded = SerializableResult.from_json(json)
    assert decoded.kind == :tuple
    assert decoded.tuple_tag == :suspend
    assert decoded.tuple_args == [42, nil]
    assert SerializableResult.unwrap(decoded) == {:suspend, 42, nil}
  end
end
