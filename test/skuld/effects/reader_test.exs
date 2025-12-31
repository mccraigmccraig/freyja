defmodule Skuld.Effects.ReaderTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Env
  alias Skuld.Effects.Reader

  describe "ask" do
    test "reads environment value" do
      env = Env.new() |> Reader.handler(:config_value)

      comp = Reader.ask()
      assert {:config_value, _} = Comp.run(comp, env)
    end
  end

  describe "asks" do
    test "applies function to environment" do
      env = Env.new() |> Reader.handler(%{name: "test", count: 42})

      comp = Reader.asks(& &1.count)
      assert {42, _} = Comp.run(comp, env)
    end
  end

  describe "local" do
    test "modifies environment for sub-computation" do
      env = Env.new() |> Reader.handler(10)

      comp =
        Comp.bind(Reader.ask(), fn before ->
          Reader.local(
            &(&1 * 2),
            Comp.bind(Reader.ask(), fn during ->
              Comp.bind(Reader.ask(), fn after_local ->
                # after_local is still inside local, so still modified
                Comp.pure({before, during, after_local})
              end)
            end)
          )
        end)

      # Note: after_local is INSIDE the local, so it sees modified value
      assert {{10, 20, 20}, _} = Comp.run(comp, env)
    end

    test "restores environment after scope exits" do
      env = Env.new() |> Reader.handler(10)

      inner = Reader.local(&(&1 * 2), Reader.ask())

      comp =
        Comp.bind(inner, fn _during ->
          # After local completes
          Reader.ask()
        end)

      assert {10, _} = Comp.run(comp, env)
    end

    test "nested local scopes" do
      env = Env.new() |> Reader.handler(1)

      comp =
        Reader.local(
          &(&1 * 10),
          Reader.local(
            &(&1 + 5),
            Reader.ask()
          )
        )

      # 1 * 10 = 10, then 10 + 5 = 15
      assert {15, _} = Comp.run(comp, env)
    end
  end
end
