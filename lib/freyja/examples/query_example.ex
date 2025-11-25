defmodule Freyja.Examples.QueryExample do
  @moduledoc """
  Demonstrates using the `Freyja.Effects.Query` effect to keep domain logic
  agnostic of storage plumbing.

  The domain code issues query requests, while handlers decide how to execute
  them (real registry vs. canned responses for tests).
  """
  import Freyja.Freer.FreerBlock

  alias Freyja.Effects.Query

  defmodule Domain do
    @moduledoc """
    Domain-level API that composes multiple backend calls via Query effect.
    """

    use Freyja.Syntax
    alias Freyja.Effects.Query
    alias Freyja.Examples.QueryExample.Backend

    defcon fetch_profile(user_id) do
      user <-
        Query.request(:users, Backend, :fetch_user, %{id: user_id})

      orders <-
        Query.request(:orders, Backend, :fetch_orders, %{
          user_id: user_id
        })

      stats <-
        Query.request(:stats, Backend, :fetch_stats, %{
          user_id: user_id
        })

      return(%{user: user, orders: orders, stats: stats})
    end
  end

  defmodule Backend do
    @moduledoc false
    def fetch_user(%{id: id}), do: %{id: id, name: "User #{id}"}
    def fetch_orders(%{user_id: id}), do: [%{id: "ord-#{id}-1", total: 42}]
    def fetch_stats(%{user_id: id}), do: %{user_id: id, total_orders: 1}
  end

  @doc """
  Build a RunBuilder that fetches a profile using the real registry.
  """
  def build_real_builder(user_id \\ 1) do
    Domain.fetch_profile(user_id)
    |> Query.Handler.run(%{
      users: :direct,
      orders: :direct,
      stats: &__MODULE__.route_stats/4
    })
  end

  def route_stats(:stats, _mod, _name, params) do
    Backend.fetch_stats(params)
    |> Map.put(:computed_via, :registry_fun)
  end

  @doc """
  Build a RunBuilder that uses `Query.TestHandler` with canned responses.
  """
  def build_test_builder(user_id \\ 1) do
    responses = %{
      Query.key(:users, Backend, :fetch_user, %{id: user_id}) => %{
        id: user_id,
        name: "Test #{user_id}"
      },
      Query.key(:orders, Backend, :fetch_orders, %{user_id: user_id}) => [%{id: "test", total: 0}],
      Query.key(:stats, Backend, :fetch_stats, %{user_id: user_id}) => %{total_orders: 0}
    }

    Domain.fetch_profile(user_id)
    |> Query.TestHandler.run(responses)
  end
end
