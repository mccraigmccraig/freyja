defmodule Skuld.Effects.StateTest do
  use ExUnit.Case, async: true

  alias Skuld.Comp
  alias Skuld.Env
  alias Skuld.Effects.State

  describe "get" do
    test "returns current state" do
      env = Env.new() |> State.handler(42)

      comp = State.get()
      assert {42, _} = Comp.run(comp, env)
    end
  end

  describe "put" do
    test "updates state" do
      env = Env.new() |> State.handler(0)

      comp =
        Comp.bind(State.put(100), fn _ ->
          State.get()
        end)

      assert {100, final_env} = Comp.run(comp, env)
      assert State.get_state(final_env) == 100
    end
  end

  describe "modify" do
    test "transforms state and returns old value" do
      env = Env.new() |> State.handler(10)

      comp =
        Comp.bind(State.modify(&(&1 + 5)), fn old ->
          Comp.bind(State.get(), fn new ->
            Comp.pure({old, new})
          end)
        end)

      assert {{10, 15}, _} = Comp.run(comp, env)
    end
  end

  describe "gets" do
    test "applies function to state" do
      env = Env.new() |> State.handler(%{count: 42, name: "test"})

      comp = State.gets(& &1.count)
      assert {42, _} = Comp.run(comp, env)
    end
  end

  describe "state threading" do
    test "threads state through computation" do
      env = Env.new() |> State.handler(0)

      comp =
        Comp.bind(State.modify(&(&1 + 1)), fn _ ->
          Comp.bind(State.modify(&(&1 + 1)), fn _ ->
            Comp.bind(State.modify(&(&1 + 1)), fn _ ->
              State.get()
            end)
          end)
        end)

      assert {3, _} = Comp.run(comp, env)
    end
  end
end
