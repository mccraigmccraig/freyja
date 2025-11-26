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
        Query.request(Backend, :fetch_user, %{id: user_id})

      orders <-
        Query.request(Backend, :fetch_orders, %{user_id: user_id})

      stats <-
        Query.request(Backend, :fetch_stats, %{user_id: user_id})

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
      Backend => &__MODULE__.route_query/3
    })
  end

  def route_query(mod, name, params) do
    result = apply(mod, name, [params])

    if name == :fetch_stats do
      Map.put(result, :computed_via, :registry_fun)
    else
      result
    end
  end

  @doc """
  Build a RunBuilder that uses `Query.TestHandler` with canned responses.

  ```
    builder = Freyja.Examples.QueryExample.build_test_builder()
    output = builder |> Freyja.Run.run()
    output.result # => %{user: ... ...}
  ```
  """
  def build_test_builder(user_id \\ 1) do
    responses = %{
      Query.key(Backend, :fetch_user, %{id: user_id}) => %{
        id: user_id,
        name: "Test #{user_id}"
      },
      Query.key(Backend, :fetch_orders, %{user_id: user_id}) => [%{id: "test", total: 0}],
      Query.key(Backend, :fetch_stats, %{user_id: user_id}) => %{total_orders: 0}
    }

    Domain.fetch_profile(user_id)
    |> Query.TestHandler.run(responses)
  end
end
