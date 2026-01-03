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

  describe "with_handler/2" do
    test "installs handler and context for computation" do
      # No handler in env - Reader.with_handler provides everything
      env = Env.new()

      comp = Reader.asks(& &1.name) |> Reader.with_handler(%{name: "test"})

      {result, _env} = Comp.run(comp, env)
      assert result == "test"
    end

    test "shadows outer handler and restores it" do
      env = Env.new() |> Reader.handler(:outer)

      comp =
        Comp.bind(Reader.ask(), fn outer_before ->
          inner = Reader.ask() |> Reader.with_handler(:inner)

          Comp.bind(inner, fn inner_result ->
            Comp.bind(Reader.ask(), fn outer_after ->
              Comp.pure({outer_before, inner_result, outer_after})
            end)
          end)
        end)

      {result, _env} = Comp.run(comp, env)

      assert {:outer, :inner, :outer} = result
    end

    test "nested scoped handlers work correctly" do
      env = Env.new()

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

      {result, _env} = Comp.run(comp, env)

      assert {:level1, :level2, :level1} = result
    end

    test "cleanup on throw" do
      alias Skuld.Effects.Throw

      env = Env.new() |> Reader.handler(:outer) |> Throw.handler()

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

      {result, _env} = Comp.run(comp, env)

      assert {:caught, :outer} = result
    end

    test "handler removed after scope when no previous handler" do
      env = Env.new()

      comp =
        Comp.bind(
          Reader.ask() |> Reader.with_handler(:config),
          fn inner_result ->
            Comp.pure({:done, inner_result})
          end
        )

      {result, final_env} = Comp.run(comp, env)

      assert {:done, :config} = result
      # Handler should be removed
      assert Env.get_handler(final_env, Reader) == nil
      # State should be removed
      assert Env.get_state(final_env, Reader) == nil
    end

    test "local still works inside handle" do
      env = Env.new()

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

      {result, _env} = Comp.run(comp, env)

      assert {10, 20, 10} = result
    end
  end
end
