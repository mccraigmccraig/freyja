defmodule Freyja.Examples.TaggedReaderDynamicContextTest do
  @moduledoc """
  Tests for the TaggedReaderDynamicContext example.

  Demonstrates how TaggedReader allows extending functionality without
  changing function signatures throughout the call stack.
  """

  use ExUnit.Case, async: true

  alias Freyja.Examples.TaggedReaderDynamicContext
  alias Freyja.Run

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defp sample_accounts do
    [
      %{
        name: "Alice Smith",
        country: "UK",
        recent_transactions: [
          %{value: 10.50, merchant: "Tesco"},
          %{value: 25.00, merchant: "ScrewFix"},
          %{value: 5.99, merchant: "Costa"}
        ]
      },
      %{
        name: "Bob Jones",
        country: "US",
        recent_transactions: [
          %{value: 45.00, merchant: "Walmart"},
          %{value: 12.50, merchant: "Starbucks"}
        ]
      },
      %{
        name: "Hans Mueller",
        country: "DE",
        recent_transactions: [
          %{value: 100.00, merchant: "Aldi"},
          %{value: 50.00, merchant: "Lidl"}
        ]
      }
    ]
  end

  defp greetings do
    %{
      "UK" => "Cheerio!",
      "US" => "Howdy!",
      "DE" => "Guten Tag!",
      "FR" => "Bonjour!"
    }
  end

  defp currencies do
    %{
      "UK" => %{symbol: "£", rate: 0.79},
      "US" => %{symbol: "$", rate: 1.0},
      "DE" => %{symbol: "€", rate: 0.92}
    }
  end

  # ============================================================================
  # Version 1: Simple Spending Summary
  # ============================================================================

  describe "Version 1: summarize_spending/1" do
    test "generates spending summary without any context" do
      accounts = sample_accounts()

      outcome =
        TaggedReaderDynamicContext.build_v1(accounts)
        |> Run.run()

      result = outcome.result

      assert length(result) == 3

      [alice, bob, hans] = result

      assert alice.name == "Alice Smith"
      assert_in_delta alice.recent_spending, 41.49, 0.01

      assert bob.name == "Bob Jones"
      assert_in_delta bob.recent_spending, 57.50, 0.01

      assert hans.name == "Hans Mueller"
      assert_in_delta hans.recent_spending, 150.00, 0.01

      # Version 1 has no greeting field
      refute Map.has_key?(alice, :greeting)
    end

    test "handles empty accounts list" do
      outcome =
        TaggedReaderDynamicContext.build_v1([])
        |> Run.run()

      assert outcome.result == []
    end

    test "handles account with no transactions" do
      accounts = [%{name: "Empty", country: "UK", recent_transactions: []}]

      outcome =
        TaggedReaderDynamicContext.build_v1(accounts)
        |> Run.run()

      [result] = outcome.result
      assert result.name == "Empty"
      assert result.recent_spending == 0
    end
  end

  # ============================================================================
  # Version 2: With Greeting (Extended Functionality)
  # ============================================================================

  describe "Version 2: summarize_with_greeting/1" do
    test "adds country-specific greeting from TaggedReader context" do
      accounts = sample_accounts()

      outcome =
        TaggedReaderDynamicContext.build_v2(accounts, greetings())
        |> Run.run()

      result = outcome.result

      [alice, bob, hans] = result

      # Same spending calculations as v1
      assert alice.name == "Alice Smith"
      assert_in_delta alice.recent_spending, 41.49, 0.01

      # But now with greetings!
      assert alice.greeting == "Cheerio!"
      assert bob.greeting == "Howdy!"
      assert hans.greeting == "Guten Tag!"
    end

    test "uses default greeting for unknown country" do
      accounts = [
        %{
          name: "Jean",
          country: "CA",
          recent_transactions: [%{value: 10.0, merchant: "Tim Hortons"}]
        }
      ]

      outcome =
        TaggedReaderDynamicContext.build_v2(accounts, greetings())
        |> Run.run()

      [result] = outcome.result
      assert result.greeting == "Hello!"
    end

    test "different greetings map produces different results" do
      accounts = sample_accounts()

      custom_greetings = %{
        "UK" => "Oi mate!",
        "US" => "Hey y'all!",
        "DE" => "Servus!"
      }

      outcome =
        TaggedReaderDynamicContext.build_v2(accounts, custom_greetings)
        |> Run.run()

      [alice, bob, hans] = outcome.result

      assert alice.greeting == "Oi mate!"
      assert bob.greeting == "Hey y'all!"
      assert hans.greeting == "Servus!"
    end
  end

  # ============================================================================
  # Version 3: Multiple Context Values
  # ============================================================================

  describe "Version 3: summarize_with_greeting_and_currency/1" do
    test "adds both greeting and formatted currency" do
      accounts = sample_accounts()

      outcome =
        TaggedReaderDynamicContext.build_v3(accounts, greetings(), currencies())
        |> Run.run()

      result = outcome.result

      [alice, bob, hans] = result

      # Alice (UK) - £ with 0.79 rate
      assert alice.name == "Alice Smith"
      assert_in_delta alice.recent_spending, 41.49, 0.01
      assert alice.greeting == "Cheerio!"
      # 41.49 * 0.79 = 32.78
      assert alice.formatted_spending == "£32.78"

      # Bob (US) - $ with 1.0 rate
      assert bob.greeting == "Howdy!"
      assert bob.formatted_spending == "$57.5"

      # Hans (DE) - € with 0.92 rate
      assert hans.greeting == "Guten Tag!"
      # 150.0 * 0.92 = 138.0
      assert hans.formatted_spending == "€138.0"
    end

    test "uses default currency for unknown country" do
      accounts = [
        %{name: "Jean", country: "CA", recent_transactions: [%{value: 100.0, merchant: "Shop"}]}
      ]

      outcome =
        TaggedReaderDynamicContext.build_v3(accounts, greetings(), currencies())
        |> Run.run()

      [result] = outcome.result
      assert result.formatted_spending == "$100.0"
    end
  end

  # ============================================================================
  # Key Point: Same generate_report/2 function for all versions
  # ============================================================================

  describe "function signature stability" do
    test "generate_report/2 works with any summarizer - no changes needed" do
      accounts = sample_accounts()

      # All three versions use the SAME generate_report/2 function
      # Only the mapper function changes

      v1 =
        TaggedReaderDynamicContext.build_v1(accounts)
        |> Run.run()

      v2 =
        TaggedReaderDynamicContext.build_v2(accounts, greetings())
        |> Run.run()

      v3 =
        TaggedReaderDynamicContext.build_v3(accounts, greetings(), currencies())
        |> Run.run()

      # All produce 3 results
      assert length(v1.result) == 3
      assert length(v2.result) == 3
      assert length(v3.result) == 3

      # All have the same names
      assert Enum.map(v1.result, & &1.name) == Enum.map(v2.result, & &1.name)
      assert Enum.map(v2.result, & &1.name) == Enum.map(v3.result, & &1.name)

      # All have the same spending
      assert Enum.map(v1.result, & &1.recent_spending) ==
               Enum.map(v2.result, & &1.recent_spending)

      assert Enum.map(v2.result, & &1.recent_spending) ==
               Enum.map(v3.result, & &1.recent_spending)

      # But v2 and v3 have extra fields that v1 doesn't
      refute Map.has_key?(hd(v1.result), :greeting)
      assert Map.has_key?(hd(v2.result), :greeting)
      assert Map.has_key?(hd(v3.result), :greeting)
      assert Map.has_key?(hd(v3.result), :formatted_spending)
    end
  end
end
