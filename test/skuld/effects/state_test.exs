defmodule Skuld.Effects.StateTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Effects.State

  describe "get" do
    test "returns current state" do
      comp = State.get() |> State.with_handler(42)
      assert {42, _} = Comp.run(comp)
    end
  end

  describe "put" do
    test "updates state" do
      comp =
        Comp.bind(State.put(100), fn _ ->
          State.get()
        end)
        |> State.with_handler(0)

      assert {100, final_env} = Comp.run(comp)
      # Note: State is scoped, so it's removed after with_handler exits
      assert State.get_state(final_env) == nil
    end
  end

  describe "modify" do
    test "transforms state and returns old value" do
      comp =
        Comp.bind(State.modify(&(&1 + 5)), fn old ->
          Comp.bind(State.get(), fn new ->
            Comp.pure({old, new})
          end)
        end)
        |> State.with_handler(10)

      assert {{10, 15}, _} = Comp.run(comp)
    end
  end

  describe "gets" do
    test "applies function to state" do
      comp = State.gets(& &1.count) |> State.with_handler(%{count: 42, name: "test"})
      assert {42, _} = Comp.run(comp)
    end
  end

  describe "state threading" do
    test "threads state through computation" do
      comp =
        Comp.bind(State.modify(&(&1 + 1)), fn _ ->
          Comp.bind(State.modify(&(&1 + 1)), fn _ ->
            Comp.bind(State.modify(&(&1 + 1)), fn _ ->
              State.get()
            end)
          end)
        end)
        |> State.with_handler(0)

      assert {3, _} = Comp.run(comp)
    end
  end

  describe "with_handler/2" do
    test "installs handler and state for computation" do
      # No handler in env - State.with_handler provides everything

      comp =
        Comp.bind(State.get(), fn x ->
          Comp.bind(State.put(x + 1), fn _ ->
            State.get()
          end)
        end)
        |> State.with_handler(42)

      {result, _env} = Comp.run(comp)
      assert result == 43
    end

    test "shadows outer handler and restores it" do
      comp =
        Comp.bind(State.get(), fn outer_before ->
          inner_comp =
            Comp.bind(State.get(), fn inner_val ->
              Comp.bind(State.put(inner_val + 1), fn _ ->
                State.get()
              end)
            end)
            |> State.with_handler(0)

          Comp.bind(inner_comp, fn inner_result ->
            Comp.bind(State.get(), fn outer_after ->
              Comp.pure({outer_before, inner_result, outer_after})
            end)
          end)
        end)
        |> State.with_handler(100)

      {result, _env} = Comp.run(comp)

      # outer: 100, inner: 0->1, outer still 100
      assert {100, 1, 100} = result
    end

    test "nested scoped handlers work correctly" do
      comp =
        Comp.bind(State.get(), fn level1 ->
          inner = State.get() |> State.with_handler(2)

          Comp.bind(inner, fn level2 ->
            Comp.bind(State.get(), fn level1_after ->
              Comp.pure({level1, level2, level1_after})
            end)
          end)
        end)
        |> State.with_handler(1)

      {result, _env} = Comp.run(comp)

      assert {1, 2, 1} = result
    end

    test "cleanup on throw" do
      alias Skuld.Effects.Throw

      comp =
        Throw.catch_error(
          Comp.bind(
            Comp.bind(State.put(42), fn _ ->
              Throw.throw(:inner_error)
            end)
            |> State.with_handler(0),
            fn _ -> Comp.pure(:unreachable) end
          ),
          fn _error ->
            Comp.bind(State.get(), fn outer_after ->
              Comp.pure({:caught, outer_after})
            end)
          end
        )
        |> State.with_handler(100)
        |> Throw.with_handler()

      {result, _env} = Comp.run(comp)

      # Outer state (100) preserved despite inner throw
      assert {:caught, 100} = result
    end

    test "handler removed after scope when no previous handler" do
      comp =
        Comp.bind(
          State.get() |> State.with_handler(10),
          fn inner_result ->
            Comp.pure({:done, inner_result})
          end
        )

      {result, final_env} = Comp.run(comp)

      assert {:done, 10} = result
      # Handler should be removed
      assert Env.get_handler(final_env, State) == nil
      # State should be removed
      assert Env.get_state(final_env, State) == nil
    end

    test "composable - pipe multiple scoped handlers" do
      comp =
        Comp.bind(State.get(), fn s ->
          Comp.bind(Skuld.Effects.Reader.ask(), fn r ->
            Comp.pure({s, r})
          end)
        end)
        |> Skuld.Effects.Reader.with_handler(:config)
        |> State.with_handler(42)

      {result, _env} = Comp.run(comp)

      assert {42, :config} = result
    end
  end
end
