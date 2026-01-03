defmodule Skuld.Effects.ReaderTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Effects.Reader

  describe "ask" do
    test "reads environment value" do
      comp = Reader.ask() |> Reader.with_handler(:config_value)
      assert {:config_value, _} = Comp.run(comp)
    end
  end

  describe "asks" do
    test "applies function to environment" do
      comp = Reader.asks(& &1.count) |> Reader.with_handler(%{name: "test", count: 42})
      assert {42, _} = Comp.run(comp)
    end
  end

  describe "local" do
    test "modifies environment for sub-computation" do
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
        |> Reader.with_handler(10)

      # Note: after_local is INSIDE the local, so it sees modified value
      assert {{10, 20, 20}, _} = Comp.run(comp)
    end

    test "restores environment after scope exits" do
      inner = Reader.local(&(&1 * 2), Reader.ask())

      comp =
        Comp.bind(inner, fn _during ->
          # After local completes
          Reader.ask()
        end)
        |> Reader.with_handler(10)

      assert {10, _} = Comp.run(comp)
    end

    test "nested local scopes" do
      comp =
        Reader.local(
          &(&1 * 10),
          Reader.local(
            &(&1 + 5),
            Reader.ask()
          )
        )
        |> Reader.with_handler(1)

      # 1 * 10 = 10, then 10 + 5 = 15
      assert {15, _} = Comp.run(comp)
    end
  end

  describe "with_handler/2" do
    test "installs handler and context for computation" do
      # No handler in env - Reader.with_handler provides everything

      comp = Reader.asks(& &1.name) |> Reader.with_handler(%{name: "test"})

      {result, _env} = Comp.run(comp)
      assert result == "test"
    end

    test "shadows outer handler and restores it" do
      comp =
        Comp.bind(Reader.ask(), fn outer_before ->
          inner = Reader.ask() |> Reader.with_handler(:inner)

          Comp.bind(inner, fn inner_result ->
            Comp.bind(Reader.ask(), fn outer_after ->
              Comp.pure({outer_before, inner_result, outer_after})
            end)
          end)
        end)
        |> Reader.with_handler(:outer)

      {result, _env} = Comp.run(comp)

      assert {:outer, :inner, :outer} = result
    end

    test "nested scoped handlers work correctly" do
      comp =
        Comp.bind(Reader.ask(), fn l1 ->
          inner = Reader.ask() |> Reader.with_handler(:level2)

          Comp.bind(inner, fn l2 ->
            Comp.bind(Reader.ask(), fn l1_after ->
              Comp.pure({l1, l2, l1_after})
            end)
          end)
        end)
        |> Reader.with_handler(:level1)

      {result, _env} = Comp.run(comp)

      assert {:level1, :level2, :level1} = result
    end

    test "cleanup on throw" do
      alias Skuld.Effects.Throw

      comp =
        Throw.catch_error(
          Comp.bind(
            Throw.throw(:error) |> Reader.with_handler(:inner),
            fn _ -> Comp.pure(:unreachable) end
          ),
          fn _error ->
            Comp.bind(Reader.ask(), fn outer_after ->
              Comp.pure({:caught, outer_after})
            end)
          end
        )
        |> Reader.with_handler(:outer)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      assert {:caught, :outer} = result
    end

    test "handler removed after scope when no previous handler" do
      comp =
        Comp.bind(
          Reader.ask() |> Reader.with_handler(:config),
          fn inner_result ->
            Comp.pure({:done, inner_result})
          end
        )

      {result, final_env} = Comp.run(comp)

      assert {:done, :config} = result
      # Handler should be removed
      assert Env.get_handler(final_env, Reader) == nil
      # State should be removed
      assert Env.get_state(final_env, Reader) == nil
    end

    test "local still works inside handle" do
      comp =
        Comp.bind(Reader.ask(), fn before_local ->
          Comp.bind(
            Reader.local(&(&1 * 2), Reader.ask()),
            fn during_local ->
              Comp.bind(Reader.ask(), fn after_local ->
                Comp.pure({before_local, during_local, after_local})
              end)
            end
          )
        end)
        |> Reader.with_handler(10)

      {result, _env} = Comp.run(comp)

      assert {10, 20, 10} = result
    end
  end
end
