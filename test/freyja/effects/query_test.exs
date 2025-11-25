defmodule Freyja.Effects.QueryTest do
  use ExUnit.Case, async: true

  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.Query
  alias Freyja.Effects.Throw
  alias Freyja.Run

  defmodule SampleQueries do
    def fetch_user(%{id: id}), do: %{id: id, name: "user-#{id}"}
  end

  defmodule RegistryHandler do
    def handle_query(:analytics, mod, name, params) do
      mod
      |> apply(name, [params])
      |> Map.put(:instrumented?, true)
    end
  end

  describe "Query.Handler" do
    test "dispatches using :direct registry entry" do
      comp =
        con [Query] do
          Query.request(:primary, SampleQueries, :fetch_user, %{id: 1})
        end

      outcome =
        comp
        |> Query.Handler.run(%{primary: :direct})
        |> Run.run()

      assert outcome.result == %{id: 1, name: "user-1"}
    end

    test "dispatches using module entry with handle_query/4" do
      comp =
        con [Query] do
          Query.request(:analytics, SampleQueries, :fetch_user, %{id: 2})
        end

      outcome =
        comp
        |> Query.Handler.run(%{analytics: RegistryHandler})
        |> Run.run()

      assert outcome.result == %{id: 2, name: "user-2", instrumented?: true}
    end

    test "returns Throw error when domain missing" do
      comp =
        con [Query] do
          Query.request(:missing, SampleQueries, :fetch_user, %{id: 3})
        end

      outcome =
        comp
        |> Query.Handler.run(%{})
        |> Throw.Handler.run()
        |> Run.run()

      assert outcome.result == {:error, {:unknown_domain, :missing}}
    end
  end

  describe "Query.TestHandler" do
    test "returns canned responses with canonical keys" do
      responses = %{
        Query.key(:search, SampleQueries, :fetch_user, %{id: 5, extra: %{foo: 1}}) => %{
          cached: true
        }
      }

      comp =
        con [Query] do
          Query.request(:search, SampleQueries, :fetch_user, %{extra: %{foo: 1}, id: 5})
        end

      outcome =
        comp
        |> Query.TestHandler.run(responses)
        |> Run.run()

      assert outcome.result == %{cached: true}
    end

    test "throws when canned response missing" do
      comp =
        con [Query] do
          Query.request(:search, SampleQueries, :fetch_user, %{id: 9})
        end

      outcome =
        comp
        |> Query.TestHandler.run(%{})
        |> Throw.Handler.run()
        |> Run.run()

      {:error, {:query_not_stubbed, key}} = outcome.result
      assert match?({:search, SampleQueries, :fetch_user, _}, key)
    end
  end
end
