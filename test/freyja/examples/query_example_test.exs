defmodule Freyja.Examples.QueryExampleTest do
  use ExUnit.Case, async: true

  alias Freyja.Examples.QueryExample
  alias Freyja.Run

  test "real builder hits live registry" do
    outcome =
      QueryExample.build_real_builder(10)
      |> Run.run()

    assert outcome.result.user == %{id: 10, name: "User 10"}
    assert [%{id: "ord-10-1", total: 42}] = outcome.result.orders
    assert outcome.result.stats.computed_via == :registry_fun
  end

  test "test builder returns canned responses" do
    outcome =
      QueryExample.build_test_builder(3)
      |> Run.run()

    assert outcome.result.user == %{id: 3, name: "Test 3"}
    assert [%{id: "test", total: 0}] = outcome.result.orders
    assert outcome.result.stats == %{total_orders: 0}
  end
end
