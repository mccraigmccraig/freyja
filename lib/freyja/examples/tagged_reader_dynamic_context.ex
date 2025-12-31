defmodule Freyja.Examples.TaggedReaderDynamicContext do
  @moduledoc """
  Example demonstrating how algebraic effects keep function signatures stable
  when requirements change.

  ## The Problem

  In traditional code, when you need to pass additional context to a function
  deep in the call stack, you have to modify every intermediate function's
  signature to thread that context through:

      # Original
      def process_accounts(accounts), do: Enum.map(accounts, &summarize/1)
      def summarize(account), do: %{name: account.name, spending: sum(account)}

      # After requirements change - need greetings context
      def process_accounts(accounts, greetings), do: Enum.map(accounts, &summarize(&1, greetings))
      def summarize(account, greetings), do: %{name: account.name, spending: sum(account), greeting: greetings[account.country]}

  Every function in the chain needs to know about `greetings`, even if it
  doesn't use it directly. This violates separation of concerns and makes
  refactoring painful.

  ## The Solution: TaggedReader

  With algebraic effects, the deep function can simply "ask" for the data
  it needs from the environment. No intermediate functions need to change:

      # Original - unchanged!
      defhefty process_accounts(accounts) do
        FxList.fx_map(accounts, &summarize/1)
      end

      # The mapper asks for what it needs
      defhefty summarize(account) do
        greetings <- TaggedReader.ask(:greetings)
        return(%{name: account.name, spending: sum(account), greeting: greetings[account.country]})
      end

  The `greetings` data is provided at the handler level, completely decoupled
  from the function signatures in between.

  ## This Example

  We have accounts with transactions:

      %{name: "Bob A", country: "UK", recent_transactions: [%{value: 10.5}, ...]}

  **Version 1**: Simple spending summary

      %{name: "Bob A", recent_spending: 20.5}

  **Version 2**: Add country-specific greeting (requirements change!)

      %{name: "Bob A", recent_spending: 20.5, greeting: "Cheerio!"}

  Notice how `generate_report/1` doesn't change at all between versions -
  only the mapper function changes, and it gets its new data via TaggedReader.
  """

  use Freyja.Syntax

  alias Freyja.Effects.FxList
  alias Freyja.Effects.Lift
  alias Freyja.Effects.TaggedReader

  # ============================================================================
  # Data Structures
  # ============================================================================

  @typedoc "A transaction record"
  @type transaction :: %{value: number(), merchant: String.t()}

  @typedoc "An account with transactions"
  @type account :: %{
          name: String.t(),
          country: String.t(),
          recent_transactions: [transaction()]
        }

  @typedoc "Version 1 report entry - just spending summary"
  @type spending_summary :: %{name: String.t(), recent_spending: number()}

  @typedoc "Version 2 report entry - with greeting"
  @type greeting_summary :: %{
          name: String.t(),
          recent_spending: number(),
          greeting: String.t()
        }

  # ============================================================================
  # Version 1: Simple Spending Summary
  # ============================================================================

  @doc """
  Generate a spending report for a list of accounts.

  This is the "orchestrating" function that maps over accounts.
  Notice it has NO knowledge of greetings or any other context -
  it just maps with a summarizer function.
  """
  defhefty generate_report(accounts, summarizer_fn) do
    FxList.fx_map(accounts, summarizer_fn)
  end

  @doc """
  Version 1: Simple spending summary.

  Just calculates total spending - no external context needed.
  """
  defhefty summarize_spending(account) do
    total = sum_transactions(account.recent_transactions)

    return(%{
      name: account.name,
      recent_spending: total
    })
  end

  # ============================================================================
  # Version 2: With Country-Specific Greeting
  # ============================================================================

  @doc """
  Version 2: Spending summary WITH country-specific greeting.

  Requirements changed! We now need a greeting based on country.
  But notice:
  - `generate_report/2` doesn't change at all
  - This function's signature doesn't change
  - We simply ASK for the greetings from the environment

  The greetings map is provided at handler configuration time,
  completely decoupled from the function call chain.
  """
  defhefty summarize_with_greeting(account) do
    # Ask for the greetings map from the environment
    greetings <- TaggedReader.ask(:greetings)

    total = sum_transactions(account.recent_transactions)
    greeting = Map.get(greetings, account.country, "Hello!")

    return(%{
      name: account.name,
      recent_spending: total,
      greeting: greeting
    })
  end

  # ============================================================================
  # Version 3: Multiple Context Values
  # ============================================================================

  @doc """
  Version 3: Even more context - currency formatting!

  Now we also want to format spending in local currency.
  Again, we just ask for what we need. No signature changes anywhere.
  """
  defhefty summarize_with_greeting_and_currency(account) do
    # Ask for multiple pieces of context
    greetings <- TaggedReader.ask(:greetings)
    currencies <- TaggedReader.ask(:currencies)

    total = sum_transactions(account.recent_transactions)
    greeting = Map.get(greetings, account.country, "Hello!")
    currency = Map.get(currencies, account.country, %{symbol: "$", rate: 1.0})

    return(%{
      name: account.name,
      recent_spending: total,
      formatted_spending: "#{currency.symbol}#{Float.round(total * currency.rate, 2)}",
      greeting: greeting
    })
  end

  # ============================================================================
  # Pure Helper
  # ============================================================================

  defp sum_transactions(transactions) do
    transactions
    |> Enum.map(& &1.value)
    |> Enum.sum()
  end

  # ============================================================================
  # Builder Functions
  # ============================================================================

  @doc """
  Build a pipeline for Version 1 (no context needed).

  ## IEx Example

  Copy and paste the following into IEx:

      alias Freyja.Examples.TaggedReaderDynamicContext

      accounts = [
        %{name: "Alice", country: "UK", recent_transactions: [%{value: 10.0, merchant: "Tesco"}]},
        %{name: "Bob", country: "US", recent_transactions: [%{value: 20.0, merchant: "Walmart"}]}
      ]

      outcome = (TaggedReaderDynamicContext.build_v1(accounts) |> Freyja.Run.run())

      # Check the result - simple spending summaries
      outcome.result
      # => [%{name: "Alice", recent_spending: 10.0}, %{name: "Bob", recent_spending: 20.0}]

      # Note: no greeting field in Version 1
      hd(outcome.result) |> Map.keys()
      # => [:name, :recent_spending]
  """
  def build_v1(accounts) do
    generate_report(accounts, &summarize_spending/1)
    |> Lift.Algebra.run()
    |> FxList.Algebra.run()
  end

  @doc """
  Build a pipeline for Version 2 (with greetings context).

  The greetings map is provided here at the handler level,
  completely separate from the business logic.

  ## IEx Example

  Copy and paste the following into IEx:

      alias Freyja.Examples.TaggedReaderDynamicContext

      # Same accounts as Version 1
      accounts = [
        %{name: "Alice", country: "UK", recent_transactions: [%{value: 10.0, merchant: "Tesco"}]},
        %{name: "Bob", country: "US", recent_transactions: [%{value: 20.0, merchant: "Walmart"}]}
      ]

      # Context provided at handler level - not threaded through functions!
      greetings = %{
        "UK" => "Cheerio!",
        "US" => "Howdy!",
        "DE" => "Guten Tag!"
      }

      outcome = (TaggedReaderDynamicContext.build_v2(accounts, greetings) |> Freyja.Run.run())

      # Now we have greetings!
      outcome.result
      # => [
      #   %{name: "Alice", recent_spending: 10.0, greeting: "Cheerio!"},
      #   %{name: "Bob", recent_spending: 20.0, greeting: "Howdy!"}
      # ]

      # The key point: generate_report/2 didn't change at all between v1 and v2
      # Only the mapper function changed, and it got its context via TaggedReader.ask
  """
  def build_v2(accounts, greetings) do
    generate_report(accounts, &summarize_with_greeting/1)
    |> Lift.Algebra.run()
    |> FxList.Algebra.run()
    |> TaggedReader.Handler.run(%{greetings: greetings})
  end

  @doc """
  Build a pipeline for Version 3 (with greetings AND currency context).

  Multiple context values, still no changes to intermediate functions.

  ## IEx Example

  Copy and paste the following into IEx:

      alias Freyja.Examples.TaggedReaderDynamicContext

      accounts = [
        %{name: "Alice", country: "UK", recent_transactions: [%{value: 10.0, merchant: "Tesco"}]},
        %{name: "Bob", country: "US", recent_transactions: [%{value: 20.0, merchant: "Walmart"}]}
      ]

      # Even more context - greetings AND currency formatting
      greetings = %{"UK" => "Cheerio!", "US" => "Howdy!"}
      currencies = %{
        "UK" => %{symbol: "£", rate: 0.79},
        "US" => %{symbol: "$", rate: 1.0}
      }

      outcome = (TaggedReaderDynamicContext.build_v3(accounts, greetings, currencies) |> Freyja.Run.run())

      # Now with currency formatting too!
      outcome.result
      # => [
      #   %{name: "Alice", recent_spending: 10.0, formatted_spending: "£7.9", greeting: "Cheerio!"},
      #   %{name: "Bob", recent_spending: 20.0, formatted_spending: "$20.0", greeting: "Howdy!"}
      # ]

      # The summarizer function just asks for what it needs:
      #   greetings <- TaggedReader.ask(:greetings)
      #   currencies <- TaggedReader.ask(:currencies)
      # No changes to generate_report/2 or any intermediate functions!
  """
  def build_v3(accounts, greetings, currencies) do
    generate_report(accounts, &summarize_with_greeting_and_currency/1)
    |> Lift.Algebra.run()
    |> FxList.Algebra.run()
    |> TaggedReader.Handler.run(%{greetings: greetings, currencies: currencies})
  end
end
